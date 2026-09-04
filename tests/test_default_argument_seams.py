"""A parameter that looks injectable but binds at definition time (#1325).

The tool under test is `tools/check_default_argument_seams.py`. These drive it
against written fixtures rather than against the repository, because a guard
whose only case is the tree it guards passes the day the tree happens to be
clean and has never been seen to fail (L1).
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools import check_default_argument_seams as seams  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent


def _tree(root: Path, files: dict[str, str]) -> Path:
    for name, body in files.items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)
    return root


def test_a_collaborator_defined_in_the_same_file_is_reported(tmp_path):
    _tree(tmp_path, {"tool.py": (
        "def measure():\n    return 1\n\n"
        "def repeatedly(run=measure):\n    return run()\n")})

    found = seams.seams(root=tmp_path)

    assert [(s.function, s.parameter) for s in found] == [("repeatedly", "run")]
    assert found[0].kind == "a function defined here"


def test_a_path_is_reported(tmp_path):
    _tree(tmp_path, {"tool.py": (
        "from pathlib import Path\n"
        "OBSERVATIONS = Path(__file__).parent / 'seen.json'\n\n"
        "def observations(path=OBSERVATIONS):\n    return path.read_text()\n")})

    found = seams.seams(root=tmp_path)

    assert [s.parameter for s in found] == ["path"]
    assert found[0].kind == "a path"


def test_a_collaborator_reached_through_a_module_is_reported(tmp_path):
    _tree(tmp_path, {"tool.py": (
        "import time\n\n"
        "def warm(now=time.monotonic):\n    return now()\n")})

    found = seams.seams(root=tmp_path)

    assert [s.parameter for s in found] == ["now"]
    assert found[0].kind == "a function reached through another module"


def test_a_constant_is_not_reported(tmp_path):
    """The whole point of a constant default is the value, and it cannot go stale."""
    _tree(tmp_path, {"tool.py": (
        "ADD_PASSES = 3\n"
        "GREETING = 'hello'\n"
        "SIZES = (1, 2, 3)\n\n"
        "def measure(passes=ADD_PASSES, greeting=GREETING, sizes=SIZES,\n"
        "            literal=7, flag=True, nothing=None):\n"
        "    return passes\n")})

    assert seams.seams(root=tmp_path) == []


def test_an_imported_constant_is_told_from_an_imported_function(tmp_path):
    _tree(tmp_path, {
        "shared.py": "MAX_ROUNDS = 4\n\ndef run_json_prompt():\n    return {}\n",
        "tool.py": (
            "from shared import MAX_ROUNDS, run_json_prompt\n\n"
            "def repair(runner=run_json_prompt, rounds=MAX_ROUNDS):\n"
            "    return runner()\n"),
    })

    found = seams.seams(root=tmp_path)

    assert [s.parameter for s in found] == ["runner"]
    assert found[0].kind == "a function imported from here"


def test_a_value_computed_in_the_signature_is_reported(tmp_path):
    """`def f(when=now())` freezes one instant for the life of the process."""
    _tree(tmp_path, {"tool.py": (
        "import time\n\n"
        "def stamp(when=time.time()):\n    return when\n")})

    found = seams.seams(root=tmp_path)

    assert [s.parameter for s in found] == ["when"]
    assert found[0].kind == "computed once, when the function was defined"


def test_a_keyword_only_default_is_reported_too(tmp_path):
    _tree(tmp_path, {"tool.py": (
        "def say():\n    pass\n\n"
        "def go(*, log=say):\n    log()\n")})

    assert [s.parameter for s in seams.seams(root=tmp_path)] == ["log"]


def test_a_method_default_is_reported_too(tmp_path):
    _tree(tmp_path, {"tool.py": (
        "import time\n\n"
        "class Recorder:\n"
        "    def __init__(self, clock=time.monotonic):\n"
        "        self.clock = clock\n")})

    assert [s.parameter for s in seams.seams(root=tmp_path)] == ["clock"]


def test_the_none_and_resolve_form_is_accepted(tmp_path):
    """The remedy this tool asks for must pass it."""
    _tree(tmp_path, {"tool.py": (
        "def measure():\n    return 1\n\n"
        "def repeatedly(run=None):\n"
        "    if run is None:\n        run = measure\n"
        "    return run()\n")})

    assert seams.seams(root=tmp_path) == []


def test_a_file_it_cannot_parse_is_reported_rather_than_skipped(tmp_path):
    """A skipped file reads exactly like a clean one (L98)."""
    _tree(tmp_path, {"broken.py": "def f(:\n"})

    with pytest.raises(seams.CannotRead) as refusal:
        seams.seams(root=tmp_path)

    assert "broken.py" in str(refusal.value)


def test_the_scan_actually_reads_the_files_it_claims_to(tmp_path):
    """A control: the count of files scanned must move with the tree.

    Written because a guard of mine earlier today was satisfied by a file it
    was not supposed to be reading at all, and the count is what shows which
    files answered.
    """
    _tree(tmp_path, {"a.py": "x = 1\n"})
    before = seams.scanned_files(root=tmp_path)

    _tree(tmp_path, {"b.py": "y = 2\n"})
    after = seams.scanned_files(root=tmp_path)

    assert [p.name for p in before] == ["a.py"]
    assert [p.name for p in after] == ["a.py", "b.py"]


def test_this_repository_has_no_such_seam():
    """The guard itself. Every finding names the remedy in its own message."""
    found = seams.seams()

    assert found == [], "\n".join(
        f"{s.file}:{s.line} {s.function}({s.parameter}={s.default}) is {s.kind}. "
        f"Default it to None and resolve it in the body."
        for s in found)


def test_the_tool_does_not_commit_the_defect_it_hunts():
    """L387: the fix is written by somebody holding the class in mind.

    Asked of the signature rather than of the source, because a literal matched
    against a file is answered by any prose in it, including the docstring above
    that spells the defect out in full.
    """
    import inspect

    for function in (seams.seams, seams.scanned_files):
        default = inspect.signature(function).parameters["root"].default
        assert default is None, f"{function.__name__} binds {default!r} at definition"


def test_a_path_built_from_another_path_is_reported(tmp_path):
    """`WORKFLOWS = REPO_ROOT / ".github"` names a directory as plainly as Path()."""
    _tree(tmp_path, {"tool.py": (
        "from pathlib import Path\n"
        "REPO_ROOT = Path(__file__).parent\n"
        "WORKFLOWS = REPO_ROOT / '.github' / 'workflows'\n\n"
        "def expected(workflows=WORKFLOWS):\n    return workflows\n")})

    found = seams.seams(root=tmp_path)

    assert [s.parameter for s in found] == ["workflows"]
    assert found[0].kind == "a path"


def test_two_constants_defined_in_terms_of_each_other_do_not_hang_it(tmp_path):
    _tree(tmp_path, {"tool.py": "A = B\nB = A\n\ndef f(x=A):\n    return x\n"})

    assert seams.seams(root=tmp_path) == []


def test_it_exits_nonzero_when_it_finds_one(tmp_path):
    _tree(tmp_path, {"tool.py": (
        "def measure():\n    return 1\n\n"
        "def repeatedly(run=measure):\n    return run()\n")})

    done = subprocess.run(
        [sys.executable, str(REPO_ROOT / "tools" / "check_default_argument_seams.py"),
         "--root", str(tmp_path)],
        capture_output=True, text=True)

    assert done.returncode == 1
    assert "repeatedly" in done.stdout
    assert "resolve it in the body" in done.stdout


def test_it_exits_zero_on_a_clean_tree(tmp_path):
    _tree(tmp_path, {"tool.py": "def f(n=3):\n    return n\n"})

    done = subprocess.run(
        [sys.executable, str(REPO_ROOT / "tools" / "check_default_argument_seams.py"),
         "--root", str(tmp_path)],
        capture_output=True, text=True)

    assert done.returncode == 0, done.stdout + done.stderr
