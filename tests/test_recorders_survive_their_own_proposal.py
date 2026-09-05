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


#: The token the proposal is opened with, which the push has to carry too.
PROPOSING_TOKEN = "RECORD_UPDATE_TOKEN"


def _checkout_step(text: str) -> str:
    """The `actions/checkout` step, to the start of the next step.

    Bounded by the next step rather than by a fixed number of lines. A window
    of N lines from an anchor stops containing what it checks the moment
    anything is added above it, and then fails on the addition rather than on
    the code (L518).
    """
    start = text.index("actions/checkout")
    rest = text[start:]
    lines = rest.splitlines()
    out = [lines[0]]
    for line in lines[1:]:
        stripped = line.lstrip()
        if stripped.startswith("- ") and not line.startswith("          "):
            break
        out.append(line)
    return "\n".join(out)


@pytest.mark.parametrize("name,text", proposers(),
                         ids=lambda v: v if isinstance(v, str) and v.endswith(".yml") else "")
def test_it_checks_out_with_the_token_it_proposes_with(name: str, text: str):
    """Both halves of the proposal run as ONE actor, or the push starts nothing.

    `gh pr create` runs with RECORD_UPDATE_TOKEN, so OPENING the pull request
    is attributed to a person and its checks run. The push inside the script
    uses whatever `actions/checkout` persisted, which is the default
    GITHUB_TOKEN, so every UPDATE to that branch is attributed to
    github-actions[bot] and GitHub holds its runs at `action_required`.

    Measured 2026-09-05 (#1390): PR #1387, freshly opened, ran 8 checks as
    danwright32. PR #1383, re-pushed the same day by the next scheduled run,
    reported 0 checks as github-actions[bot], and wait_for_checks.py correctly
    refuses to call an empty answer green, so it could never merge.

    The failure only ever appears on a RE-push, which is exactly when the
    newest measurement is the one waiting (L403).
    """
    step = _checkout_step(text)

    assert PROPOSING_TOKEN in step, (
        f"{name} checks out with the default token, so the push inside "
        f"propose_recorded_change.sh is attributed to github-actions[bot] and "
        f"its checks are held at action_required. The pull request then "
        f"reports no checks at all, which reads the same as checks that have "
        f"not started (#1390)")


def test_the_checkout_step_reader_stops_at_the_next_step():
    """The control on `_checkout_step`. Reading past the step would find a
    token belonging to some later step and report a workflow as fixed when its
    checkout is untouched, which is the whole defect wearing the remedy's
    clothes (L178)."""
    described = ("      - uses: actions/checkout@v5\n"
                 "\n"
                 "      - name: Something else\n"
                 "        env:\n"
                 "          GH_TOKEN: ${{ secrets.RECORD_UPDATE_TOKEN }}\n")

    assert PROPOSING_TOKEN not in _checkout_step(described), (
        "a token belonging to a later step is being read as the checkout's")


# ── a recorder records MAIN, so it must only be woken by main (#1398) ────────


#: How a workflow woken by another one can establish that main is what ran.
#:
#: Two spellings, both real and both sufficient, rather than one required form.
#: `record-suite-count.yml` is woken by the macOS suite, which runs on every
#: pull request too, so it has to name the branch. `record-guard-costs.yml` is
#: woken by the guard sweep and filters on the EVENT being `schedule`, and a
#: scheduled run only ever runs on the default branch, so it gets there another
#: way. Demanding one exact spelling would fail a workflow that is already
#: correct, and demanding neither is what let 61 needless runs happen in a day.
ONLY_MAIN = ("head_branch == 'main'", "workflow_run.event == 'schedule'")


def woken_by_another_workflow() -> list[tuple[str, str]]:
    """The proposers that run on another workflow finishing."""
    return [(name, text) for name, text in proposers()
            if "workflow_run:" in text]


def test_the_sweep_finds_the_woken_recorders():
    """The positive control. A sweep matching nothing reports every recorder as
    correctly scoped, which is the reading this file's predecessor produced
    when the line it keyed on moved (L98, L100)."""
    names = [name for name, _ in woken_by_another_workflow()]

    assert len(names) >= 2, f"only {names} are woken by another workflow"


@pytest.mark.parametrize("name,text", woken_by_another_workflow(),
                         ids=lambda v: v if isinstance(v, str) and v.endswith(".yml") else "")
def test_it_only_wakes_for_a_run_of_main(name: str, text: str):
    """A recorder records a number ABOUT main, so a branch's run must not wake
    it.

    `workflow_run` fires for every run of the named workflow, including a pull
    request's. Measured 2026-09-05: 73 macOS runs that day, 47 on pull
    requests, and `record-suite-count.yml` woke and ran 61 times because its
    condition asked only whether the run went green. `record-guard-costs.yml`
    skipped 40 of its 41 wake-ups, which is this rule already working.

    A job is billed a whole minute whatever it does (L310), and the repository
    is going private where those minutes are capped, so this is real cost. The
    worse half is that the run it then READS may be a branch's (#1398).
    """
    condition = text[text.index("if:"):] if "if:" in text else ""

    assert any(spelling in condition for spelling in ONLY_MAIN), (
        f"{name} wakes on any run of the workflow it watches, including a pull "
        f"request's, so it records a number about main from whichever branch "
        f"finished last and bills a minute every time (#1398). Name the branch, "
        f"or filter the event to `schedule` the way record-guard-costs.yml does")
