"""#233: the Swift suite must be able to block a bad pull request.

On 2026-08-09 a compile error in test setup sat red on main across eight
merges. Only the older Xcode in CI rejects it, and both signals available at
merge time were structurally unable to show it: pull requests skipped the Swift
job entirely, and running the suite locally passes because the local Xcode is
the one that ACCEPTS the code CI rejects. There was nowhere to look that would
have caught it before merging.

These assert the trigger rules that close that hole, so re-adding the blanket
pull-request skip goes red instead of going unnoticed for another eight merges.

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


# ── deriving the trigger paths from what the tests actually read ──────────────

def _outside_inputs() -> set[str]:
    """Repo-relative files the Swift tests read from outside `PostRollApp/`.

    Read out of the sources rather than listed by hand, because a list
    maintained beside the tests drifts the moment someone adds a fixture and
    does not think of this file, which is the exact failure #246 is about.
    """
    found: set[str] = set()
    for source in sorted(SWIFT_TESTS.rglob("*.swift")):
        text = source.read_text()
        for literal in re.findall(r'appendingPathComponent\(\s*"([^"]+)"', text):
            if literal.startswith("/") or ".." in literal:
                continue
            # Only literals that name a real committed file are inputs; the
            # rest are paths built at runtime inside a temp directory.
            if (REPO_ROOT / literal).is_file():
                found.add(literal)
    return found


def _trigger_paths(swift: str) -> list[str]:
    """The `paths:` entries on the pull_request trigger, in order."""
    after = swift.split("paths:", 1)[1]
    entries = []
    for line in after.splitlines()[1:]:
        stripped = line.strip()
        if not stripped.startswith("- "):
            break
        entries.append(stripped[2:].strip().strip('"').strip("'"))
    return entries


def _is_covered(path: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        if pattern.endswith("/**"):
            if path.startswith(pattern[:-2]):
                return True
        elif pattern == path:
            return True
    return False


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


# ── the cost trade it replaces ────────────────────────────────────────────────

def test_pull_requests_only_pay_when_they_touch_the_app(swift):
    # macOS runner minutes bill at a 10x multiplier on a private repo, so a
    # Python-only PR must still cost nothing. Touching the app is the only way
    # a PR can break the Swift build.
    assert "paths:" in swift
    assert "PostRollApp/**" in swift


def test_every_file_the_swift_tests_read_from_outside_the_app_triggers_the_job(swift):
    # #246: two Swift tests read cross-language fixtures under `tests/`, so a
    # PR that regenerates one of them can turn the Swift suite red while the
    # job that would have said so never runs. A skipped job looks exactly like
    # a passing one, which is the same shape of hole #245 was written to close.
    #
    # Derived from the sources so a fixture added later is covered without
    # anyone remembering this file exists.
    inputs = _outside_inputs()
    assert inputs, (
        "found no cross-language inputs at all; the regex has stopped matching "
        "how the Swift tests locate fixtures, so this test now proves nothing")

    patterns = _trigger_paths(swift)
    uncovered = sorted(p for p in inputs if not _is_covered(p, patterns))
    assert not uncovered, (
        f"the Swift tests read {uncovered} but no trigger path covers them, so "
        f"a PR changing those files would skip the job that they can break")


def test_a_change_to_this_workflow_runs_it(swift):
    # Otherwise editing the trigger rules is the one change that cannot be
    # verified by the job it configures.
    assert ".github/workflows/swift.yml" in swift


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


def test_a_change_to_a_media_generator_runs_the_reference_frames(swift):
    # The templates are what the frames are OF, so a change to one that does not
    # trigger the job leaves the check it was written for unrun.
    assert "postroll/media/**" in swift


def test_a_missing_font_or_encoder_fails_the_job_rather_than_skipping(swift):
    # Both of these turn a skip into a hard error. A reference check that
    # quietly skips for want of a system font reports green having compared
    # nothing, which is the exact failure mode it exists to close.
    assert "POSTROLL_REQUIRE_GOLDENS" in swift
    assert "POSTROLL_REQUIRE_FFMPEG" in swift
