"""#1243: a recorded suite cost has to say which machine produced it.

`.github/workflows/swift.yml` recorded the Swift suite as "294s of test bodies
serially and 106s wall in parallel, and the packing is near perfect up to four
workers". That reading came from this Mac. The comment sits in the job that runs
on a GitHub macOS runner, and the runner reports THREE cores: measured on run
33760431737, `Swift suite on 3 workers, 3 cores`, 2,895 tests, and xcodebuild's
own observer reporting 212.162 seconds elapsed.

#1103 reasoned from the 106s figure to conclude the tests were the small
remainder of `swift-unit` and roughly 400 of 528 seconds were compiling. With
the runner's own reading the test run is the largest single phase of the job, so
the bare number sent a whole milestone's planning at the wrong half of the job.
A number with a date on it reads as MORE trustworthy, not less (L316, L210).

So the readings live in `tests/fixtures/swift_suite_cost.json`, one per machine,
each carrying the cores it ran on and the command that re-measures it, in the
shape `guard_sweep_timing.json` and `swift_suite_count.json` already use.

## What this does NOT check

It does not check that a reading is still TRUE. Nothing here can: re-measuring
means dispatching the workflow. What it checks is that no reading can be
recorded without the machine it came from, and that the recorded runner is still
the runner the job asks for, so moving `swift-unit` to a larger runner (#1246)
goes red naming the readings it just invalidated rather than leaving them to be
read as current.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = REPO_ROOT / "tests" / "fixtures" / "swift_suite_cost.json"
SWIFT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"

#: Every field a reading has to carry. `cores` is the one the issue is about;
#: the rest are what make the number re-measurable rather than a dated sentence.
REQUIRED = (
    "machine",
    "cores",
    "workers",
    "wall_seconds",
    "serial_test_body_seconds",
    "heaviest_class_seconds",
    "tests",
    "measured_on",
    "measured_from",
    "re_measure_with",
)


def _record() -> dict:
    assert FIXTURE.exists(), (
        f"{FIXTURE} is missing, so the workflow comment points at nothing and "
        "the suite cost is unrecorded again"
    )
    return json.loads(FIXTURE.read_text())


def _readings() -> list[dict]:
    readings = _record().get("readings")
    assert readings, (
        f"{FIXTURE} holds no readings. An empty record and a machine that has "
        "never been measured are different things (L98)"
    )
    return readings


# ── the machine travels with the number ──────────────────────────────────────

def test_every_reading_names_the_machine_it_came_from() -> None:
    for reading in _readings():
        missing = [field for field in REQUIRED if field not in reading]
        assert not missing, (
            f"the {reading.get('machine', 'unnamed')} reading is missing "
            f"{missing}. A reading without its cores is exactly the figure "
            "#1243 was opened about"
        )
        assert isinstance(reading["cores"], int) and reading["cores"] > 0, (
            f"the {reading['machine']} reading records "
            f"{reading['cores']!r} cores"
        )


def test_both_machines_are_recorded_rather_than_one_standing_for_both() -> None:
    """One reading cannot be told from a number that applies everywhere.

    The defect was a local figure read as a CI one, and a record holding only
    the runner would invite the same mistake in the other direction: someone
    sizing a local change against a 3 core wall clock.
    """
    cores = {reading["cores"] for reading in _readings()}
    assert len(cores) >= 2, (
        "only one machine is recorded, so a reader still has no way to tell "
        f"which of theirs it describes: {sorted(cores)}"
    )


def test_the_recorded_runner_is_the_runner_the_job_still_asks_for() -> None:
    """A runner change invalidates the reading, and must say so.

    #1246 is costing a larger macOS runner. If it lands, every figure below is
    a reading of a machine the job no longer uses, and nothing else in the repo
    would notice.
    """
    runner = _record().get("runner_image")
    assert runner, f"{FIXTURE} does not say which runner image it was measured on"
    job = SWIFT_WORKFLOW.read_text().split("\n  swift-unit:", 1)
    assert len(job) == 2, "swift-unit is not in swift.yml under the name this reads"
    body = job[1].split("\n  reference-frames:", 1)[0]
    declared = [
        line.split("runs-on:", 1)[1].strip()
        for line in body.split("\n")
        if line.strip().startswith("runs-on:")
    ]
    assert declared == [runner], (
        f"the recorded readings come from {runner!r} but swift-unit now runs on "
        f"{declared!r}. Re-measure with the command in {FIXTURE.name} and record "
        "the new machine beside the old one, rather than leaving a reading of a "
        "retired runner to be read as current"
    )


# ── the numbers have to be consistent with each other ────────────────────────

def test_no_reading_claims_better_than_perfect_packing() -> None:
    """A wall clock under serial-over-workers is a transcription error.

    The old comment's claim, near perfect packing up to four workers, is the
    kind of thing this catches: on the runner the serial bodies total 475.8s
    across 3 workers, so a perfectly packed run is 158.6s, and the measured wall
    is 212.2s. That is 75% of perfect, not near perfect.
    """
    for reading in _readings():
        floor = reading["serial_test_body_seconds"] / reading["workers"]
        assert reading["wall_seconds"] >= floor, (
            f"the {reading['machine']} reading is {reading['wall_seconds']}s of "
            f"wall for {reading['serial_test_body_seconds']}s of test bodies on "
            f"{reading['workers']} workers, which is faster than the work "
            "divides. One of those three numbers is wrong"
        )


def test_no_reading_finishes_sooner_than_its_heaviest_class() -> None:
    """xcodebuild packs by CLASS, so one class is the floor no count of workers
    gets under. A wall clock below it means the classes were not measured from
    the same run as the wall."""
    for reading in _readings():
        assert reading["wall_seconds"] >= reading["heaviest_class_seconds"], (
            f"the {reading['machine']} reading finishes in "
            f"{reading['wall_seconds']}s while its heaviest class alone is "
            f"{reading['heaviest_class_seconds']}s"
        )


def test_a_reading_counts_the_tests_it_timed() -> None:
    for reading in _readings():
        assert reading["tests"] > 1_000, (
            f"the {reading['machine']} reading times {reading['tests']} tests, "
            "which is not this suite. Seconds without a count cannot tell a "
            "suite that GREW from one that got slower"
        )


# ── the workflow points at the record rather than restating it ───────────────

def test_the_workflow_sends_the_reader_to_the_record() -> None:
    text = SWIFT_WORKFLOW.read_text()
    assert "swift_suite_cost.json" in text, (
        "swift.yml does not cite tests/fixtures/swift_suite_cost.json, so the "
        "next person sizing this job reads whatever number is nearest and the "
        "machine it came from is unstated again"
    )


def test_the_superseded_local_figure_is_not_still_stated_as_this_jobs_cost() -> None:
    """The exact sentence #1243 was opened about.

    Asserting the absence of one rendering is usually a weak guard (L103). Here
    the rendering IS the defect: this string is a 12 core Mac's wall clock
    written in the job that runs on a 3 core runner.
    """
    text = SWIFT_WORKFLOW.read_text()
    assert "106s wall in parallel" not in text, (
        "swift.yml still records the local Mac's 106s wall clock as this job's cost"
    )
