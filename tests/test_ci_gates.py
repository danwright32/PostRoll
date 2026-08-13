"""#233: the Swift suite must be able to block a bad pull request.

On 2026-08-09 a compile error in test setup sat red on main across eight
merges. Only the older Xcode in CI rejects it, and both signals available at
merge time were structurally unable to show it: pull requests skipped the Swift
job entirely, and running the suite locally passes because the local Xcode is
the one that ACCEPTS the code CI rejects. There was nowhere to look that would
have caught it before merging.

These assert the trigger rules that close that hole, so re-adding the blanket
pull-request skip goes red instead of going unnoticed for another eight merges.

The rule is now the strongest available: every pull request runs both jobs,
whatever it touched (#431). The paths filter that used to narrow it is gone, and
the tests that checked its coverage went with it, because a filter that runs
everything has no coverage to check. Two of those tests were themselves written
after a filter skipped precisely the change that broke the suite (#246), which is
the argument for not having one.

They read the workflow as text rather than parsing YAML, which is a real
limitation: a rule expressed in a shape these strings do not match would pass
here. Adding a YAML parser to the runtime dependencies for one test is not
worth it, and the strings below are the exact ones that were wrong.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
SWIFT = WORKFLOWS / "swift.yml"
TESTS = WORKFLOWS / "tests.yml"
SWIFT_TESTS = REPO_ROOT / "PostRollApp" / "Tests"


@pytest.fixture
def swift() -> str:
    return SWIFT.read_text()


def _jobs(swift: str) -> dict[str, str]:
    """Each job's name and body, so a claim about one job cannot be satisfied by
    something sitting in the other.

    Comment lines are dropped first. Every job here is introduced by prose that
    explains it, and prose about one job routinely names what the other one runs,
    so a scan that read the comments would report the two jobs as one the moment
    somebody documented them properly (L103). That is not hypothetical: the
    comment describing #507's shard balance names the reference-frame test files,
    and it sat above the job rather than inside it.
    """
    after = swift.split("\njobs:", 1)[1]
    jobs: dict[str, str] = {}
    current = None
    for line in after.splitlines():
        if line.strip().startswith("#"):
            continue
        header = re.match(r"^  ([A-Za-z][\w-]*):\s*$", line)
        if header:
            current = header.group(1)
            jobs[current] = ""
        elif current:
            jobs[current] += line + "\n"
    return jobs


# ── the hole that let a red main through ──────────────────────────────────────

def test_the_swift_suite_runs_on_pull_requests(swift):
    assert "pull_request:" in swift, (
        "the Swift suite must be able to block a bad PR; skipping it there is "
        "how a compile error reached main eight times")


def test_the_blanket_pull_request_skip_is_gone(swift):
    # The exact condition that caused it.
    assert "github.event_name != 'pull_request'" not in swift


def test_it_is_not_hiding_back_in_the_python_workflow():
    # Moving the job to its own file is only a fix while the old one stays
    # gone. Two swift jobs would run twice and cost double.
    assert "swift" not in TESTS.read_text().lower()


# ── every pull request runs it, whatever it touched (#431) ────────────────────


def test_no_paths_filter_narrows_what_a_pull_request_runs(swift):
    """The decision this replaces two years of tuning with.

    A filter has to be maintained against everything the suite reads, and the
    failure mode of getting it wrong is silent: the job is skipped, and a skipped
    job is indistinguishable from a passing one. That happened twice, once by
    skipping pull requests entirely (#233) and once by filtering to the app folder
    while two tests read fixtures living beside the Python suite (#246).

    Re-adding a filter is therefore a deliberate reopening of that hole, and it
    fails here rather than being noticed eight merges later.
    """
    assert "paths:" not in swift, (
        "a paths filter is back on the macOS workflow, so some pull requests will "
        "skip these checks, and a skipped check reads exactly like a passing one")


def test_the_two_halves_run_as_separate_jobs(swift):
    """Otherwise a Swift compile error is reported only after the reels render.

    They are independent: one compiles and tests the app, the other renders
    templates through Python. In one job they ran in sequence and the wall clock
    was their sum, so the fast signal arrived last.
    """
    jobs = _jobs(swift)

    assert len(jobs) >= 2, f"the macOS work is back in one job: {list(jobs)}"
    running_swift = [name for name, body in jobs.items()
                     if "-scheme PostRollTests" in body]
    running_frames = [name for name, body in jobs.items()
                      if "test_golden_frames.py" in body]

    assert running_swift and running_frames, (
        f"could not find both halves: swift in {running_swift}, "
        f"reference frames in {running_frames}")
    assert set(running_swift).isdisjoint(running_frames), (
        "the Swift tests and the reference frames are in the same job again, so "
        "the quick signal waits on the slow one")


def test_the_reference_frame_job_does_not_pay_for_a_build(swift):
    """It needs this runner's FONTS, not a compiler.

    Left in, an Xcode build would put two and a half minutes back onto the job
    that is already the slow half, for nothing it uses.
    """
    frames = next(body for name, body in _jobs(swift).items()
                  if "test_golden_frames.py" in body)

    assert "xcodebuild" not in frames, (
        "the reference-frame job builds the app, which it never uses")
    assert "xcodegen" not in frames, (
        "the reference-frame job generates the Xcode project, which it never uses")


def test_pull_requests_still_run_the_app_checks(swift):
    # The pull_request trigger has to be there at all: this whole file exists
    # because it once was not.
    assert "pull_request:" in swift
    assert "branches: [main]" in swift


def test_pushes_to_main_run_it_regardless_of_what_changed(swift):
    # The paths filter narrows what a PR pays for. It must not narrow what main
    # is verified against, or a merge could still land on an unverified main.
    push_block = swift.split("pull_request:")[0]

    assert "push:" in push_block
    assert "branches: [main]" in push_block
    assert "paths:" not in push_block, (
        "a paths filter on the push trigger would leave main unverified for "
        "any merge that did not touch the filtered paths")


def test_it_can_still_be_run_by_hand(swift):
    # How the fix in #244 was verified under CI's own Xcode before merging,
    # which is the only way to check this class of failure ahead of time.
    assert "workflow_dispatch:" in swift


# ── what it actually runs ─────────────────────────────────────────────────────

def test_it_runs_the_unit_test_scheme_not_the_gui_one(swift):
    # A headless runner cannot reliably drive XCUIApplication, and a job that
    # fails for that reason teaches everyone to ignore it.
    assert "-scheme PostRollTests" in swift
    assert "-scheme PostRoll " not in swift


def test_it_regenerates_the_project_rather_than_trusting_the_checked_in_copy(swift):
    # project.yml is the manifest; the .xcodeproj is generated from it, so a
    # stale checked-in copy would test a different set of files than the repo
    # describes.
    assert "xcodegen generate" in swift


# ── the reference frames have somewhere to run (#163) ─────────────────────────

def test_the_reference_frames_run_on_a_mac(swift):
    # They render the real templates, which draw with macOS system fonts the
    # Linux runner in tests.yml does not have. A recorded frame can only be
    # compared where it can be reproduced.
    assert "runs-on: macos" in swift
    assert "tests/test_golden_frames.py" in swift, (
        "the reference-frame checks are not run by any job, so they only ever "
        "guard a template on whoever remembers to run them locally")


def test_a_missing_font_or_encoder_fails_the_job_rather_than_skipping(swift):
    # Both of these turn a skip into a hard error. A reference check that
    # quietly skips for want of a system font reports green having compared
    # nothing, which is the exact failure mode it exists to close.
    assert "POSTROLL_REQUIRE_GOLDENS" in swift
    assert "POSTROLL_REQUIRE_FFMPEG" in swift


# ── #105: nothing floats ──────────────────────────────────────────────────────

REQUIREMENTS = REPO_ROOT / "requirements.txt"


def test_every_dependency_is_pinned_exactly():
    """requirements.txt states this rule at the top and then had to keep it.

    A ">=" line means every CI run installs whatever shipped that morning, so
    an upstream release breaks the build with no change on our side, which has
    already happened once (#105). `ruff>=0.6` sat one line below the comment
    saying not to do that, which is how a stated rule quietly stops being one.

    Derived from the file rather than a list here, so the next floored line is
    caught on the day it lands.
    """
    floated = []
    for line in REQUIREMENTS.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "==" not in stripped:
            floated.append(stripped)
    assert not floated, (
        "these dependencies are not pinned exactly, so CI installs whatever "
        f"shipped that morning: {floated}")


def test_the_requirements_file_is_not_empty():
    # A gutted file would make the check above pass by having nothing to check.
    lines = [ln for ln in REQUIREMENTS.read_text().splitlines()
             if ln.strip() and not ln.strip().startswith("#")]
    assert len(lines) >= 4, f"only {len(lines)} dependencies listed, so the scan proves little"
