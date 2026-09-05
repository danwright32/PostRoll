"""Every recorder proposes its change through the one shared script (#1311).

`record-suite-count.yml` and `record-guard-costs.yml` each re-measure a number
and open a pull request from a branch named for the DAY, so the second run of
any day meets the first run's own branch. That block was copied into both
workflows character for character, and it was wrong in both: the push it used
is one git refuses in exactly the state the copy existed to handle. 37 failed
runs in one day, 37 emails, none of them about anything either workflow
measures.

The first version of this file guarded the copy by reading the workflow TEXT
and asserting the remedy was PRESENT. It passed for a day while the remedy did
nothing (L1, L3). So the behaviour is now proved by running the script for real
against a git remote, in tests/test_recorded_change_is_proposed.py, and what is
left here is the one thing a behaviour test cannot see: whether a workflow
goes through that script at all, or has quietly grown a third copy.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
SCRIPT = REPO_ROOT / "tools" / "propose_recorded_change.sh"

#: A workflow that opens a pull request from a branch it pushes.
#:
#: Found by the SHAPE rather than listed, so a third recorder written later is
#: covered without anybody remembering this file (L96, L247). Both spellings
#: count: one that calls the shared script, and one that has grown its own
#: `gh pr create`, which is the thing being guarded against.
PROPOSES = re.compile(r"propose_recorded_change\.sh|gh pr create")


def _without_comments(text: str) -> str:
    """The workflow with its comment lines blanked.

    A text guard cannot tell the line describing a construct from the line
    using it, and the comments here name every construct below (L103, L135).
    """
    return "\n".join("" if line.lstrip().startswith("#") else line
                     for line in text.splitlines())


def proposers() -> list[tuple[str, str]]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        text = _without_comments(path.read_text(encoding="utf-8"))
        if PROPOSES.search(text):
            found.append((path.name, text))
    return found


def test_the_sweep_finds_the_recorders():
    """The positive control. A sweep matching nothing reports every recorder as
    safe, which is exactly what they were not, and it is how the previous
    version of this file turned itself into three silent skips when the line it
    keyed on moved into the script (L98, L100)."""
    names = [name for name, _ in proposers()]

    assert len(names) >= 2, f"only {names} propose a recorded change"
    for expected in ("record-suite-count.yml", "record-guard-costs.yml"):
        assert expected in names, f"{expected} is not among the proposers found"


@pytest.mark.parametrize("name,text", proposers(),
                         ids=lambda v: v if isinstance(v, str) and v.endswith(".yml") else "")
def test_it_proposes_through_the_shared_script(name: str, text: str):
    """The push that survives meeting its own branch lives in one place, and
    the only way to get it is to call it. A workflow that opens the pull
    request itself has a second copy of a rule that was wrong in both copies
    last time (L370)."""
    assert "propose_recorded_change.sh" in text, (
        f"{name} proposes a change without tools/propose_recorded_change.sh, "
        f"so it carries its own copy of the push, the branch reuse and the "
        f"already-open check (#1311)")

    assert "gh pr create" not in text, (
        f"{name} calls gh pr create directly as well as going through the "
        f"shared script, so which one opens the proposal depends on which runs "
        f"first")


@pytest.mark.parametrize("name,text", proposers(),
                         ids=lambda v: v if isinstance(v, str) and v.endswith(".yml") else "")
def test_it_names_the_record_and_the_words_it_proposes(name: str, text: str):
    """Nothing the script proposes has a default, so a caller that leaves one
    out is refused rather than proposing one record under another's title
    (L168). That refusal is a red workflow run; catching it here is cheaper."""
    call = text[text.index("propose_recorded_change.sh"):]

    for flag in ("--record", "--branch-prefix", "--title", "--body"):
        assert flag in call, f"{name} calls the script without {flag}"


def test_the_script_is_executable():
    """It is invoked by path from the workflow, not through `bash`, so the mode
    bit is load bearing and a checkout that lost it fails only in CI (L177)."""
    assert SCRIPT.exists(), f"{SCRIPT} is gone but the workflows still call it"
    assert SCRIPT.stat().st_mode & 0o111, f"{SCRIPT} is not executable"


def test_the_comment_stripper_is_why_the_checks_above_can_be_trusted():
    """The control on `_without_comments`. Without it the checks read prose
    about a call as the call: this file's own predecessor reported both
    recorders as broken while they were fixed, because the fix's comment named
    the construct the guard was hunting for (L159)."""
    described = "          # gh pr create is never called here\n          gh pr view x"

    assert "gh pr create" not in _without_comments(described), (
        "a comment naming the call is still being read as the call")
    assert "gh pr view" in _without_comments(described), (
        "the real call is being stripped along with the prose about it")
