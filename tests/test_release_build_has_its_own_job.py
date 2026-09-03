"""#1242: the Release build runs BESIDE the tests rather than ahead of them.

Measured on run 33760431737 and recorded in #1103: `swift-unit` runs its steps
one after another, and `Build the app` was 194 of the job's 620 seconds, 152.4
of them inside ONE `SwiftCompile` task, because Release compiles whole module
and the runner has three cores. All 194 were on the pull request critical path.

Giving it a job of its own changes none of the compiling. It changes WHEN the
compiling happens: alongside the test job instead of before it.

## What must not change while that happens

CI builds Release on purpose. Commit 208477c closed a gap in which a
`sending 'fm' risks causing data races` error in PhotoAssignmentView sat on
main since #535 with every check green, because CI built Debug while
`make install` builds Release, and the two compile differently.

So this file asserts the build KEPT its configuration as well as that it moved.
A move that quietly dropped `-configuration Release` would read as exactly this
speedup and would silently reintroduce that defect class, which is the half of
the change nobody would look at (L142).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.wait_for_checks import _job_blocks, expected_checks

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
SWIFT = WORKFLOWS / "swift.yml"

#: The job the Release build moves INTO. Named once here and asserted against
#: the workflow, rather than each test spelling it, so a rename fails in one
#: place rather than making a test read nothing (L100).
RELEASE_JOB = "release-build"
TEST_JOB = "swift-unit"

RELEASE_FLAG = "-configuration Release"


@pytest.fixture
def jobs() -> dict[str, str]:
    """Every job in swift.yml, by key, comments stripped.

    Comments here explain the very flags being asserted, so a scan of the raw
    text could be satisfied by prose describing a setting that had been deleted
    (L103).
    """
    text = "\n".join(
        line for line in SWIFT.read_text(encoding="utf-8").splitlines()
        if not line.strip().startswith("#"))
    found = dict(_job_blocks(text))
    assert found, "no jobs could be read out of swift.yml, so this reads nothing"
    return found


def test_the_release_build_left_the_test_job(jobs):
    """The point of the change: it is no longer on the test job's critical path."""
    assert TEST_JOB in jobs, f"there is no {TEST_JOB} job any more, so this reads nothing"
    assert RELEASE_FLAG not in jobs[TEST_JOB], (
        f"the {TEST_JOB} job still builds Release, so its 194 seconds are still "
        "in front of the tests rather than beside them, which is the whole "
        "point of #1242")


def test_the_release_build_has_a_job_of_its_own(jobs):
    """Left the test job is not the same as arrived somewhere (L3).

    Without this, deleting the step entirely passes the test above.
    """
    assert RELEASE_JOB in jobs, (
        f"there is no {RELEASE_JOB} job in swift.yml, so the Release build did "
        "not move, it went away, and nothing compiles the configuration that "
        "reaches the Applications folder")
    assert RELEASE_FLAG in jobs[RELEASE_JOB], (
        f"the {RELEASE_JOB} job does not name Release, so the job exists and "
        "builds the wrong configuration")


def test_the_moved_build_still_compiles_one_architecture(jobs):
    """#993 rides along with the step. Release builds universal by default, so
    a move that dropped this flag doubles the job it was just made cheaper."""
    assert "ONLY_ACTIVE_ARCH=YES" in jobs.get(RELEASE_JOB, ""), (
        f"the {RELEASE_JOB} job lost ONLY_ACTIVE_ARCH=YES in the move, so it "
        "compiles the whole module twice and links twice for a slice that runs "
        "on no machine this app is installed on")


def test_a_pull_request_actually_waits_for_the_new_job():
    """A job nothing waits for is a job that cannot fail a pull request (L98).

    `tools/wait_for_checks.py` derives the bar from the workflows that trigger
    on pull requests, so this is what makes the new job a gate rather than a
    thing that happens.
    """
    names = {check.name for check in expected_checks(WORKFLOWS)}
    assert RELEASE_JOB in names, (
        f"{RELEASE_JOB} is not in the set a pull request waits for, so a "
        f"Release-only compile error would not block a merge. Derived: "
        f"{sorted(names)}")
