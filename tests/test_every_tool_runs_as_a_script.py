"""Every command in `tools/` can actually be run as a command (#1090).

Running a file as a script puts its OWN directory on `sys.path`, not the repo
root, so a module doing `from tools import ...` finds nothing. pytest adds the
root, so a tool can import perfectly inside the suite and die on its first line
when somebody types the command out of the Makefile. That is exactly what #1090
did to `tools/record_test_durations.py` when it moved the record's shape into
`tools/measured_record.py`: 4,743 tests green, and

    venv/bin/python tools/record_test_durations.py
    ModuleNotFoundError: No module named 'tools'

Built is not wired (L3), and the suite is the wrong place to look for the
difference.

The tool is IMPORTED under script path rules, never executed. Executing it is
what the first version of this file did, and it is not a small mistake: several
of these tools write files or call GitHub, and `record_test_durations.py`
started running the whole suite, so the check timed out rather than answering.
So the module is loaded under a name that is not `__main__`, which leaves every
`if __name__ == "__main__":` block alone, while `sys.path` is set to exactly
what the shell would have given it: the tool's own directory, and a working
directory that is NOT the repository, so the repo root cannot arrive by accident
and make a broken tool look fine.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS = REPO_ROOT / "tools"

#: Modules in `tools/` that are libraries rather than commands.
#:
#: Named rather than derived from the absence of a `__main__` block, because
#: that absence is exactly what a broken command looks like too. They are
#: checked all the same: a library that cannot be imported under script rules
#: breaks every command that imports it, which is how #1090 happened.
NOT_COMMANDS = frozenset({"__init__.py"})

#: Loaded under this name so no `if __name__ == "__main__":` block fires.
AS_A_MODULE = "_postroll_import_check"

#: Long enough for an import that reads a fixture, short enough that a tool
#: which starts doing real work is reported rather than hanging the suite. The
#: slowest import measured on 2026-08-31 was under a second.
IMPORT_DEADLINE_SECONDS = 30

#: The module is registered in `sys.modules` before it is executed, which is
#: what an ordinary import does. Without that line `@dataclass` fails on every
#: module that uses one: dataclasses resolves a field's annotation through
#: `sys.modules[cls.__module__]`, finds None, and raises an AttributeError deep
#: inside the standard library. That failure looks exactly like a broken tool
#: and is entirely the harness's, which is worth knowing before trusting a red
#: run here (L11).
SCRIPT = """
import importlib.util, sys
sys.path.insert(0, {tools!r})
spec = importlib.util.spec_from_file_location({name!r}, {path!r})
module = importlib.util.module_from_spec(spec)
sys.modules[{name!r}] = module
spec.loader.exec_module(module)
"""


def tools() -> list[Path]:
    found = sorted(p for p in TOOLS.glob("*.py") if p.name not in NOT_COMMANDS)
    assert found, (
        f"no modules were found under {TOOLS.relative_to(REPO_ROOT)}, so this "
        "sweep checks nothing and reads exactly like a clean one (L98)")
    return found


def import_as_a_script(path: Path, cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-c",
         SCRIPT.format(tools=str(TOOLS), name=AS_A_MODULE, path=str(path))],
        capture_output=True, text=True, cwd=cwd,
        timeout=IMPORT_DEADLINE_SECONDS)


def test_the_sweep_finds_the_tools_at_all():
    assert len(tools()) > 10, (
        f"only {len(tools())} modules were swept; the repository has many more, "
        "so NOT_COMMANDS has swallowed them or the glob has stopped matching")


@pytest.mark.parametrize("tool", [p.name for p in tools()])
def test_the_tool_imports_the_way_a_script_does(tool: str, tmp_path: Path):
    found = import_as_a_script(TOOLS / tool, cwd=tmp_path)
    assert found.returncode == 0, (
        f"tools/{tool} cannot be imported the way running it as a command "
        f"imports it:\n{found.stderr.strip()[-900:]}\n\n"
        "Running a file as a script puts its own directory on sys.path, not the "
        "repo root. Add the two lines tools/check_guards.py carries:\n"
        "    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))"
    )


def test_a_module_missing_its_path_insert_would_be_caught(tmp_path: Path):
    """The positive control, so this file is shown catching the defect rather
    than asserting that it would (L1).

    A module importing `tools.` with no path insert, loaded under script rules,
    is the exact shape #1090 shipped.
    """
    broken = tmp_path / "broken.py"
    broken.write_text("from tools.measured_record import scale_from\n")
    found = import_as_a_script(broken, cwd=tmp_path)
    assert found.returncode != 0 and "ModuleNotFoundError" in found.stderr, (
        "a module importing `tools.` with no path insert loaded cleanly, so the "
        "sweep above is checking something that cannot happen and is vacuous. "
        f"stderr was: {found.stderr!r}")


def test_the_control_would_pass_with_the_insert(tmp_path: Path):
    """The other half of the control, in the same fixture (L159).

    Without it the check above is equally satisfied by a harness in which
    NOTHING can import, which would fail every tool for a reason unrelated to
    the rule.
    """
    fixed = tmp_path / "fixed.py"
    fixed.write_text(
        "import sys\n"
        f"sys.path.insert(0, {str(REPO_ROOT)!r})\n"
        "from tools.measured_record import scale_from\n"
        "assert scale_from\n")
    found = import_as_a_script(fixed, cwd=tmp_path)
    assert found.returncode == 0, found.stderr
