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

from pathlib import Path

import pytest


WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"
SWIFT = WORKFLOWS / "swift.yml"
TESTS = WORKFLOWS / "tests.yml"


@pytest.fixture
def swift() -> str:
    return SWIFT.read_text()


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
