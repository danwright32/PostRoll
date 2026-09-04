"""#1321: a recorder that cannot run twice in a day because of its own output.

`record-suite-count.yml` and `record-guard-costs.yml` each push a branch named
for the DAY and open a pull request from it. The second run of any day meets the
first run's own proposal: the branch exists, `--force-with-lease` has no remote
tracking ref to compare against on a fresh checkout so it refuses, and
`gh pr create` would fail anyway because a pull request is already open on that
head.

Measured 2026-09-04: 37 failed runs in one day, 37 emails, none of them about
the count the workflow measured. That is the standing red L538 warns about, and
the reason it hurts is that a genuinely new failure then arrives in the same
list indistinguishable from this one.

This is not the concurrency case. The earlier run SUCCEEDED. What blocks the
next one is a person not having merged its proposal yet (L393).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

#: Every workflow that proposes a change from a branch named for the day.
#:
#: Found by the SHAPE rather than listed, so a third recorder written later is
#: covered without anybody remembering this file (L96, L247).
DAILY_BRANCH = re.compile(r'branch="[\w-]+/\$\(date -u \+%Y-%m-%d\)"')


def _without_comments(text: str) -> str:
    """The workflow with its comment lines blanked.

    Written after the first version of the ordering check below reported both
    recorders as broken while they were fixed: the fix's own comment says
    "`gh pr create` is skipped when today\'s proposal is already open", and a
    raw search found THAT before the real call. A text guard cannot tell the
    line describing a construct from the line using it (L103, L135).
    """
    return "\n".join("" if line.lstrip().startswith("#") else line
                      for line in text.splitlines())


def proposers() -> list[tuple[str, str]]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        text = path.read_text(encoding="utf-8")
        if DAILY_BRANCH.search(text):
            found.append((path.name, _without_comments(text)))
    return found


def test_the_sweep_finds_the_recorders():
    """The positive control. A sweep matching nothing would report every
    recorder as safe, which is exactly what they were not (L98, L100)."""
    names = [name for name, _ in proposers()]

    assert len(names) >= 2, f"only {names} propose from a daily branch"
    for expected in ("record-suite-count.yml", "record-guard-costs.yml"):
        assert expected in names, f"{expected} is not among the proposers found"


@pytest.mark.parametrize("name,text", proposers(), ids=lambda v: v if isinstance(v, str) and v.endswith(".yml") else "")
def test_the_lease_has_something_to_compare_against(name: str, text: str):
    """`--force-with-lease` refuses when there is no remote tracking ref, and a
    fresh checkout has none, so without the fetch the lease is not a safety
    check: it is a guaranteed refusal on the second run of every day."""
    if "--force-with-lease" not in text:
        pytest.skip(f"{name} does not use a lease, so it has nothing to compare")

    assert 'git fetch origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"' in text, (
        f"{name} pushes with --force-with-lease and never fetches the branch, "
        f"so the lease has no remote ref to compare against and the push is "
        f"refused every time today's proposal already exists (#1321)")


@pytest.mark.parametrize("name,text", proposers(), ids=lambda v: v if isinstance(v, str) and v.endswith(".yml") else "")
def test_it_does_not_try_to_open_a_proposal_that_is_already_open(name: str, text: str):
    """Pushing the branch has ALREADY updated the open pull request, so there is
    nothing left to create and creating again is what fails. A run that finds
    its own proposal open is a success that says so, not an error (L11)."""
    at = text.index("gh pr create")
    before = text[:at]

    assert "gh pr view" in before, (
        f"{name} calls gh pr create without first asking whether today's "
        f"proposal is already open, so every run after the first of the day "
        f"fails on a pull request it opened itself (#1321)")


@pytest.mark.parametrize("name,text", proposers(), ids=lambda v: v if isinstance(v, str) and v.endswith(".yml") else "")
def test_the_first_run_of_the_day_is_not_broken_by_the_fix(name: str, text: str):
    """The fetch has to tolerate the branch not existing, which is the state on
    the first run of every day. A fix that made the common case fail would be
    worse than the defect (L104)."""
    fetch = next(line for line in text.splitlines()
                 if "refs/remotes/origin/${branch}" in line)

    assert fetch.rstrip().endswith("|| true"), (
        f"{name} fetches a branch that does not exist yet on the first run of "
        f"the day and does not tolerate the failure, so it would break every "
        f"first run to fix the second")



def test_the_comment_stripper_is_why_the_ordering_check_can_be_trusted():
    """The control on `_without_comments`. If it stopped stripping, the check
    above would pass on prose about the call rather than on the call, which is
    how it read as broken while it was fixed (L159)."""
    described = "          # gh pr view is asked before gh pr create\n          gh pr create x"

    assert "gh pr view" not in _without_comments(described), (
        "a comment naming the call is still being read as the call")
    assert "gh pr create" in _without_comments(described), (
        "the real call is being stripped along with the prose about it")
