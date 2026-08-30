"""A Swift leg that ran HALF the suite is refused, not just one that ran none (#1017).

`tools/suite_counts.py` refuses a leg reporting no total and a leg reporting
zero. Nothing refuses one that executed half. That is not a hypothetical shape:
Overture's parallel-execution experiment executed 4,875 of 8,595 tests with no
crash line and a verdict naming twelve failures, and nothing anywhere said the
other 3,720 had never run. A run that loses a worker's share still prints
TEST SUCCEEDED and reads as a full green run (L98).

#992 is this repo's version of that change, which is why the floor lands first:
an instrument fitted AFTER the change it is meant to judge has no reading of the
suite before it (L309).

The floor is derived from a MEASURED count, not an asserted one. The record
carries the number, the commit it was measured at and the date, so it can be
re-measured rather than believed (L316); the tolerance that turns it into a
floor lives in code, where the reason for its size can be read.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from tools.suite_counts import (
    FLOOR_TOLERANCE,
    RECORDED_COUNT,
    SuiteCountError,
    recorded_swift_count,
    swift_run_meets_floor,
)


def test_a_leg_that_ran_half_the_suite_is_refused():
    """The defect this exists for: a plausible total that is far too small."""
    with pytest.raises(SuiteCountError) as refusal:
        swift_run_meets_floor(executed=1300, recorded=2599)

    message = str(refusal.value)
    assert "1300" in message, "the refusal must name what actually ran"
    assert "2599" in message, "and what the suite was last measured at"


def test_a_full_run_is_accepted():
    """The positive control, in the same fixture as the refusal above (L159).

    Without it, the refusal is equally satisfied by a floor nothing can ever
    clear, and the whole check would be a suite that can only go red.
    """
    swift_run_meets_floor(executed=2599, recorded=2599)


def test_a_run_one_test_short_of_the_floor_is_refused():
    """The boundary, asserted from both sides so the tolerance is a real edge.

    A tolerance tested only from far away is a tolerance whose SIZE nothing
    holds: it would pass identically at 2% and at 90%.
    """
    floor = int(2599 * (1 - 0.02))

    swift_run_meets_floor(executed=floor, recorded=2599)

    with pytest.raises(SuiteCountError):
        swift_run_meets_floor(executed=floor - 1, recorded=2599)


def test_a_record_of_zero_is_its_own_refusal():
    """An unset or corrupt record must not read as a floor everything clears.

    A recorded count of zero derives a floor of zero, which every run on earth
    passes, so the check would go on reading as an active safeguard while
    refusing nobody (L98, L182). It is a different failure from a short run and
    gets a different message (L11): one is a suite that did not run, the other
    is a record that was never written.
    """
    with pytest.raises(SuiteCountError) as refusal:
        swift_run_meets_floor(executed=2599, recorded=0)

    message = str(refusal.value)
    assert "record" in message.lower(), (
        "the refusal must point at the RECORD, not at the run, which was fine")


# ── The record the floor is derived from ──────────────────────────────────────


def test_the_committed_record_holds_a_real_measured_count():
    """The record every run is judged against, read from where it really lives.

    Measured on the runner at 417574d: 2,599 tests. The issue that asked for
    this floor recorded 2,546, which was already 53 out by the time the work
    started, which is the whole reason the record carries the commit and date it
    was measured at rather than a bare number (L316).
    """
    count = recorded_swift_count()

    assert count > 2000, (
        "the recorded count must be the real suite's, not a placeholder: a "
        "small number here is a floor the suite clears while asleep")


def test_an_absent_record_is_refused_by_name(tmp_path):
    """A missing record must not silently become a floor of nothing.

    This is the failure that arrives when the file is renamed, moved, or never
    committed, and it has to be told apart from a record that is present and
    says zero (L11), because one is fixed by writing the file and the other by
    re-running the suite.
    """
    missing = tmp_path / "not-here.json"

    with pytest.raises(SuiteCountError) as refusal:
        recorded_swift_count(missing)

    assert "not-here.json" in str(refusal.value), (
        "the refusal must name the path it looked in, or it cannot be acted on")


def test_a_record_missing_its_count_is_refused(tmp_path):
    """A well-formed file that does not answer the question is still no answer.

    A `.get("count", 0)` here would turn a typo in the key into a floor of zero,
    which every run clears, so the guard would report green while measuring
    nothing (L138: an absent setting read as an empty value silently accepts).
    """
    wrong_shape = tmp_path / "swift_suite_count.json"
    wrong_shape.write_text(json.dumps({"measured_at": "417574d"}), encoding="utf-8")

    with pytest.raises(SuiteCountError):
        recorded_swift_count(wrong_shape)


def test_the_record_path_points_inside_the_repo():
    """The default path is the committed record, not something built at runtime."""
    assert RECORDED_COUNT.name.endswith(".json")
    assert RECORDED_COUNT.exists(), (
        f"{RECORDED_COUNT} is the record every Swift run is judged against and "
        f"it must be committed, or the floor is absent on a fresh checkout")


# ── The floor applied to a real run, not just to the arithmetic ───────────────


REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL = REPO_ROOT / "tools" / "suite_counts.py"


def _swift_transcript(executed: int) -> str:
    """The shape xcodebuild really prints, with the grand total last."""
    return (
        f"Test Suite 'All tests' passed at 2026-08-29 22:00:00.000.\n"
        f"\t Executed {executed} tests, with 0 failures (0 unexpected) in "
        f"118.4 (119.0) seconds\n"
        f"** TEST SUCCEEDED **\n")


def _run_leg(leg: str, *command: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(TOOL), "run", leg, "--", *command],
                          capture_output=True, text=True, cwd=REPO_ROOT)


def test_a_swift_leg_that_ran_half_the_suite_fails_though_xcodebuild_said_success():
    """The defect, seen to refuse rather than described (L1).

    `/bin/echo` exits 0, exactly as xcodebuild does for a spec that matched
    nothing and for a run that lost a worker. Judging the leg on that alone is
    what lets a half run report as a full suite.
    """
    half = recorded_swift_count() // 2
    result = _run_leg("swift", "/bin/echo", _swift_transcript(half))

    assert result.returncode != 0, (
        "the leg passed on a transcript reporting half the suite: "
        + result.stdout + result.stderr)
    assert str(half) in (result.stdout + result.stderr), (
        "the refusal must name what actually ran")


def test_a_full_swift_leg_still_passes():
    """The positive control, in the same fixture (L159).

    The count comes from the record rather than being typed here, so the two
    cannot drift into disagreeing about what a full run is (L41).
    """
    result = _run_leg("swift", "/bin/echo",
                      _swift_transcript(recorded_swift_count()))

    assert result.returncode == 0, result.stdout + result.stderr
    assert "tests" in result.stdout


def test_the_count_it_judged_is_printed():
    """The number has to be visible, or a passing run proves nothing to a reader.

    A floor that refuses silently and passes silently leaves an operator with no
    way to tell a suite that grew from one that is sitting just above the line.
    """
    result = _run_leg("swift", "/bin/echo",
                      _swift_transcript(recorded_swift_count()))

    assert str(recorded_swift_count()) in result.stdout, result.stdout


# ── The runner is held to the same floor as the desk ─────────────────────────


WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"


def test_the_runner_reads_its_own_test_count():
    """CI is where a short run is most likely and least likely to be noticed.

    `make test-swift` has read a count since #932, but the `swift-unit` job
    called xcodebuild DIRECTLY, so on the runner no count was read at all: the
    one place nobody is watching the scroll was the one place with no number.
    A floor that only local runs are held to is a floor for the person least
    likely to need it (L3: wired is not proven, and this half was not wired).
    """
    workflow = WORKFLOW.read_text(encoding="utf-8")
    step = workflow.split("name: Run the Swift unit tests", 1)
    assert len(step) == 2, "the step this guard is written about was renamed"

    body = step[1].split("- name:", 1)[0]
    assert "suite_counts.py" in body, (
        "the swift-unit step runs xcodebuild directly, so nothing reads how "
        "many tests it executed and a half run reports as a full green run")


MAKEFILE = REPO_ROOT / "Makefile"


def test_the_tests_ci_runs_and_local_skips_stay_inside_the_tolerance():
    """One record serves two selections only while the gap between them is small.

    The runner runs the whole `PostRollTests` scheme. `make test-swift` skips the
    REVIEW_TESTS dump methods, so a local run is legitimately SHORTER than the
    recorded count, which was measured on the runner. Today that is 3 tests
    against a tolerance of 51, so both clear the same floor.

    That is a property, not a coincidence, and nothing else holds it. Growing
    REVIEW_TESTS past the tolerance would put every local run under the floor,
    and the failure would name a short suite rather than the skip list that
    caused it (L11, L220: splitting the work re-aims a guard calibrated on the
    whole). This fails first instead, naming the real cause.
    """
    makefile = MAKEFILE.read_text(encoding="utf-8")
    block = makefile.split("REVIEW_TESTS := ", 1)
    assert len(block) == 2, "REVIEW_TESTS was renamed and this guard went blind"

    skipped = [line for line in block[1].split("\n\n", 1)[0].splitlines()
               if "PostRollTests/" in line]
    allowed = recorded_swift_count() * FLOOR_TOLERANCE

    assert len(skipped) < allowed / 2, (
        f"{len(skipped)} tests are skipped locally against a tolerance of "
        f"{allowed:.0f}. Local runs are approaching the floor recorded from the "
        f"runner, so either record a separate count for the local selection or "
        f"widen the tolerance deliberately")
