"""#992: read the Swift executed-test count from the result bundle, not stdout.

Running the Swift suite in parallel is worth roughly 280s of the pull request
critical path, and `swift-unit` is the last job to finish on 29 of 52 recent
runs. What stood in the way is measured rather than assumed. Three runs on
2026-08-30, Xcode 26.6, the version PostRollApp/.ci-xcode-version pins:

* serial, declaration order: TEST SUCCEEDED, 2,614 tests, 294s of test bodies
* serial, randomised class order: TEST SUCCEEDED, 2,614 tests, no order
  dependencies (1 of 287 class positions unchanged, so the shuffle was real)
* parallel, 6 workers: TEST SUCCEEDED in 104s

## Why the transcript stops being readable

xcodebuild changes its output format in parallel mode, and the change removes
the one line this repository depends on:

    Executed 2614 tests, with 0 failures

Zero occurrences of it in the whole 2,940 line parallel transcript. Three tools
read that line, all importing one regex from `tools/check_guards.py`:
`suite_counts.py`, `check_guards.py` and `record_suite_count.py`. Both refusals
are loud, which is the design working, and it is still a hard blocker: the count
is the ONLY thing that tells a full run from one that lost a worker's share
(L98), and losing a worker's share is precisely the failure parallelism adds.

## Why counting the per-test lines instead does not work

The parallel run appeared to be one test short of the serial one. It was not.
Six worker processes write to one stdout and one line was corrupted mid-write:

    sts.testTheFaintToneMatcherSeesEverySpelling()' passed on 'My Mac ...'

A count taken from interleaved stdout undercounted by exactly 1 in 2,614 on the
first run anybody tried. That is well inside the 51 test tolerance the floor
allows, so the floor would not have caught it, and it means any line-counting
reader is measuring the WRITES rather than the tests.

## So the count comes from the result bundle

`xcrun xcresulttool get test-results summary` reads a structure the workers
wrote through the test framework rather than through a shared pipe. Measured on
the same two bundles: the parallel run and the serial run both report
`totalTestCount: 2614`, which is also what proved no test had been lost.

Nothing here falls back to the transcript when the bundle cannot be read. A
fallback written for a source being ABSENT must not be reached when it is
present and broken (L214), and the transcript in a parallel run is exactly that:
present, and quietly missing the number.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.suite_counts import (
    SuiteCountError,
    count_from_summary,
    swift_tests_run,
)


def summary(**over) -> dict:
    base = {"result": "Passed", "totalTestCount": 2614, "passedTests": 2614,
            "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
    base.update(over)
    return base


# ── reading the number ────────────────────────────────────────────────────────


def test_the_total_is_taken_from_the_bundle_summary():
    assert count_from_summary(summary()) == 2614


def test_a_failed_run_still_reports_how_many_tests_it_reached():
    """The count says the suite was REACHED; the runner's exit code says whether
    it was GREEN. One field answering both questions is how a run of nothing
    came to read as a full suite (L53), so a red bundle must still count."""
    assert count_from_summary(summary(result="Failed", failedTests=1,
                                      passedTests=2613)) == 2614


def test_a_summary_with_no_total_is_refused_rather_than_counted_as_zero():
    """An absent field is not a measurement of zero. Reported as a broken read,
    because the two need different fixes (L11)."""
    payload = summary()
    del payload["totalTestCount"]
    with pytest.raises(SuiteCountError) as refused:
        count_from_summary(payload)
    assert "totalTestCount" in str(refused.value)


def test_a_total_of_zero_is_its_own_refusal():
    """A test spec that matches nothing still exits green, so a run of zero
    looks exactly like a full one (L98)."""
    with pytest.raises(SuiteCountError) as refused:
        count_from_summary(summary(totalTestCount=0, passedTests=0))
    assert "0 tests" in str(refused.value)


def test_a_total_that_is_not_a_whole_number_is_refused():
    """A value parsed from another tool's output must never feed a comparison
    directly (L50). Anything that is not a count is a broken read."""
    for bad in ("2614", None, -3, 12.5):
        with pytest.raises(SuiteCountError):
            count_from_summary(summary(totalTestCount=bad))


def test_a_reply_that_is_not_an_object_at_all_is_refused():
    for bad in ([], "Passed", None, 7):
        with pytest.raises(SuiteCountError):
            count_from_summary(bad)


# ── choosing where to read from ───────────────────────────────────────────────


def _parallel_transcript() -> str:
    """A parallel run's real shape: no Executed line anywhere in it."""
    return ("Test suite 'BannerLegibilityTests' started on 'My Mac - xctest (1)'\n"
            "Test case 'BannerLegibilityTests.testOne()' passed on "
            "'My Mac - xctest (1)' (0.003 seconds)\n"
            "** TEST SUCCEEDED **\n")


def test_without_a_bundle_the_transcript_is_still_what_is_read():
    """`check_guards` proves one guard at a time and has no bundle, so the
    transcript reader has to keep working exactly as it did (L263)."""
    log = "\t Executed 2614 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n"
    assert swift_tests_run(log) == 2614


def test_a_parallel_transcript_with_no_bundle_is_refused_not_guessed_at():
    """The state this whole change exists to avoid reaching silently."""
    with pytest.raises(SuiteCountError) as refused:
        swift_tests_run(_parallel_transcript())
    assert "executed-tests total" in str(refused.value)


def test_a_bundle_is_read_even_when_the_transcript_has_no_number(tmp_path):
    bundle = tmp_path / "run.xcresult"
    bundle.mkdir()
    counted = swift_tests_run(
        _parallel_transcript(), bundle=bundle,
        read_summary=lambda path: summary())
    assert counted == 2614


def test_the_bundle_wins_over_a_transcript_that_does_have_a_number(tmp_path):
    """Not a tie-break for tidiness. In a parallel run the transcript can carry
    a number from a single sub-suite while the bundle holds the run's total, and
    silently preferring the smaller one is a short run reading as a full one."""
    bundle = tmp_path / "run.xcresult"
    bundle.mkdir()
    log = "\t Executed 12 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n"
    assert swift_tests_run(log, bundle=bundle,
                           read_summary=lambda path: summary()) == 2614


def test_a_bundle_that_cannot_be_read_never_falls_back_to_the_transcript(tmp_path):
    """L214. The transcript in a parallel run is present and quietly wrong, so a
    fallback written for an ABSENT source would land straight on it and report a
    number nobody should trust."""
    bundle = tmp_path / "run.xcresult"
    bundle.mkdir()
    log = "\t Executed 12 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n"

    def broken(path):
        raise SuiteCountError("xcresulttool exited 1")

    with pytest.raises(SuiteCountError) as refused:
        swift_tests_run(log, bundle=bundle, read_summary=broken)
    assert "xcresulttool" in str(refused.value)


def test_a_bundle_path_that_is_not_there_is_named_as_missing(tmp_path):
    """Distinct from a bundle that is there and unreadable: one means the run
    never wrote it, the other that the reader broke (L11)."""
    with pytest.raises(SuiteCountError) as refused:
        swift_tests_run("", bundle=tmp_path / "never-written.xcresult",
                        read_summary=lambda path: summary())
    assert "never-written.xcresult" in str(refused.value)
