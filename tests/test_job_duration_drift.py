"""Noticing that a CI job got slower, before an audit has to (#1019).

Nothing here read its own duration over time. Measured from the Actions API for
the week of 2026-08-22 to 08-29: the Swift test step's median went from 476s
over the first eight runs to 530s over the last eight, 11% in one week, and the
guard sweep drifted to within a few entries of its 1,800s deadline and went red
four times before anyone measured the distance (#989). The swift.yml comment
sizing the job still said 2,250 tests against 2,599 today.

## Why halves rather than the latest run

The obvious instrument, compare the newest run against the spread of the ones
before it, fires on ordinary noise: a single CI run's duration swings with the
runner it landed on, so a threshold set where that variation lives turns the
warning into something everyone learns to ignore (L36, L172).

What actually FOUND the drift above was comparing one half of the window with
the other, so that is what this does. It is the same reading the issue was
written from, rather than a different one that happens to be easier.

## Why the test count travels with the seconds

Seconds alone cannot tell a suite that grew from a suite that got slower, and
those need opposite responses. A count rising with the seconds is a suite doing
more work; the same count taking longer is the regression worth a warning. The
count comes from the record #1017 already writes.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.check_job_durations import (
    Drift,
    drift_of,
    job_durations,
)
from tools.guard_sweep_history import PROOF_STEP


def _series(older: list[float], recent: list[float]) -> list[float]:
    """A window in the order the API returns it: newest first."""
    return list(reversed(older + recent))


def test_a_job_that_got_materially_slower_is_reported():
    """The reading the issue was written from: 476s becoming 530s."""
    verdict = drift_of("swift-unit", _series([470, 476, 480, 478],
                                             [525, 530, 535, 532]))

    assert verdict.state is Drift.SLOWER
    assert "swift-unit" in verdict.message, (
        "a notice that does not name the job leaves the reader with nowhere "
        "to go (L80)")


def test_a_steady_job_is_not_reported():
    """The positive control, in the same fixture (L159).

    Without it the warning is equally satisfied by a rule that fires on
    everything, which is the failure mode that gets a check ignored.
    """
    verdict = drift_of("python", _series([185, 190, 187, 192],
                                         [188, 186, 191, 189]))

    assert verdict.state is Drift.STEADY


def test_ordinary_run_to_run_noise_does_not_fire():
    """One slow run among steady ones is the runner, not a regression.

    This is the case that decides whether anyone keeps reading the warnings.
    """
    verdict = drift_of("swift-unit", _series([470, 476, 480, 478],
                                             [475, 610, 477, 479]))

    assert verdict.state is Drift.STEADY, (
        f"a single slow run fired the warning: {verdict.message}")


def test_a_job_that_got_faster_is_named_as_that():
    """Distinct from steady, because it is the reading that judges #991 and #992.

    An improvement reported as "nothing to see" makes this instrument useless
    for the two issues it exists to serve, which are both changes whose whole
    purpose is to move this number (L11).
    """
    verdict = drift_of("swift-unit", _series([520, 530, 525, 528],
                                             [410, 405, 415, 408]))

    assert verdict.state is Drift.FASTER


def test_too_short_a_window_is_refused_rather_than_called_steady():
    """Not enough history is not evidence of health (L98).

    A window that cannot be split into two halves says nothing at all, and
    reporting that as STEADY is a green verdict nothing measured.
    """
    verdict = drift_of("swift-unit", [476.0, 480.0])

    assert verdict.state is Drift.NOT_ENOUGH_HISTORY
    assert verdict.state is not Drift.STEADY


@pytest.mark.parametrize("state", list(Drift))
def test_every_state_reports_without_gating(state):
    """This warns; it never fails a build.

    Stated over every state rather than per state, because the freshness check
    it is modelled on records that having one failure mode gate and another not
    leaves a reader working out which is which.
    """
    assert Drift(state).exit_code == 0


# ── Reading the API's real shape, not one I invented ─────────────────────────


REPO_ROOT = Path(__file__).resolve().parent.parent
REAL_JOBS = REPO_ROOT / "tests" / "fixtures" / "gh_actions_jobs_real.json"


def test_durations_are_read_from_the_shape_the_api_really_sends():
    """Against a captured real reply, not a stub of my own assumption (L52).

    `gh_actions_jobs_real.json` was captured from this repository's own Actions
    API for `tests/test_wait_for_checks.py`. Reusing it means this reader is
    held to what GitHub actually sends, including the trailing-Z timestamps that
    `datetime.fromisoformat` will not take without help.
    """
    captured = json.loads(REAL_JOBS.read_text(encoding="utf-8"))
    runs = [{"jobs": run["jobs"]} for run in captured.values()]

    series = job_durations(runs)

    assert "swift-unit" in series, (
        f"no swift-unit series came out of the real reply: {sorted(series)}")
    assert all(seconds > 0 for seconds in series["swift-unit"]), (
        "a real completed job measured as zero seconds, so the timestamps "
        "were not actually parsed")


def test_an_unfinished_job_contributes_nothing_rather_than_zero():
    """A running job has no duration yet, and zero is not "no duration".

    A zero would pull the median down and read as the job having got FASTER,
    which is the opposite of what an unfinished run means, and it is the
    direction nothing downstream would question (L215).
    """
    series = job_durations([
        {"jobs": [{"name": "swift-unit",
                   "started_at": "2026-08-17T20:19:51Z",
                   "completed_at": None}]},
        {"jobs": [{"name": "swift-unit",
                   "started_at": "2026-08-17T20:19:51Z",
                   "completed_at": "2026-08-17T20:25:50Z"}]},
    ])

    assert series["swift-unit"] == [359.0], (
        "the unfinished run was counted, so an in-flight job reads as an "
        "instant one")


# ── The series is actually taken, not merely takeable ────────────────────────


GUARDS = REPO_ROOT / ".github" / "workflows" / "guards.yml"


def test_something_actually_runs_the_duration_check():
    """Built is not wired (L3), and an instrument nothing invokes reads nothing.

    Beside the sweep freshness notice, on one shard of the existing job, for the
    reason that file already records at length: a new JOB is a new CHECK NAME,
    and `tests/test_wait_for_checks.py` calibrates its bar against a recorded
    reply from a real pull request, so adding a name costs a knowingly red
    merge. A step on a job that already reports buys the same reading for none
    of that.
    """
    workflow = GUARDS.read_text(encoding="utf-8")

    assert "check_job_durations.py" in workflow, (
        "nothing runs the duration series, so it can only ever be read by "
        "somebody who already suspects the answer")


def test_the_duration_check_reads_the_workflow_on_the_critical_path():
    """swift.yml is the job the drift was measured on, so it must be covered.

    A series that happens to watch the cheap workflows while the expensive one
    drifts is the instrument reporting green about the wrong thing (L320).
    """
    workflow = GUARDS.read_text(encoding="utf-8")
    named = workflow.split("- name: Say whether any CI job's duration has moved", 1)
    assert len(named) == 2, "the step this guard is written about was renamed"

    # The step's own body, taken up to the next step rather than by a fixed
    # number of lines: an anchor counted in lines stops containing the code it
    # checks the moment a comment is added (L518).
    step = named[1].split("      - name:", 1)[0]

    assert "check_job_durations.py" in step, (
        f"the step no longer runs the duration check: {step!r}")
    assert "swift.yml" in step, (
        f"the duration check does not read swift.yml, which is the workflow "
        f"the drift was measured on: {step!r}")


def test_a_skipped_job_contributes_nothing():
    """GitHub stamps a skipped job's end BEFORE its start, so it measures negative.

    Measured on 2026-08-30 against this repository's own API: the `full` job,
    skipped on pull requests, reports started_at 13:19:13Z and completed_at
    13:19:12Z. That is one second of NEGATIVE duration, and before this it went
    into the series and dragged the median under zero, tripping UNREADABLE on
    every run.

    The refusal was at least honest rather than a wrong number, but a check
    whose entire value is that it does not cry wolf cannot afford to warn on
    every run about a job that was never going to run (L36).

    Excluded by its SHAPE rather than by its `skipped` label. A label check was
    written first and removed: `check_guards` reported it SURVIVED its mutation,
    because every skipped job the API really produces is already caught by the
    non-positive duration, so nothing could show the branch was needed (L29).
    """
    series = job_durations([
        {"jobs": [{"name": "full", "conclusion": "skipped",
                   "started_at": "2026-08-30T13:19:13Z",
                   "completed_at": "2026-08-30T13:19:12Z"}]},
        {"jobs": [{"name": "swift-unit", "conclusion": "success",
                   "started_at": "2026-08-30T13:19:13Z",
                   "completed_at": "2026-08-30T13:25:12Z"}]},
    ])

    assert "full" not in series, (
        f"the skipped job entered the series: {series}")
    assert series["swift-unit"] == [359.0], (
        "the positive control did not survive, so this test would pass on a "
        "reader that dropped everything (L159)")


def test_a_negative_duration_never_reaches_the_series():
    """Belt and braces on the SHAPE, not just on the label.

    Keying only on `conclusion == "skipped"` would leave any other source of an
    inverted pair going straight into the median, and a negative number there
    is never a measurement of anything (L50). The two checks answer different
    questions and both are kept.
    """
    series = job_durations([
        {"jobs": [{"name": "odd", "conclusion": "success",
                   "started_at": "2026-08-30T13:19:13Z",
                   "completed_at": "2026-08-30T13:19:12Z"}]},
    ])

    assert "odd" not in series, f"a negative duration was recorded: {series}"


# ── a job that had nothing to do is not a reading of that job (#989) ──────────
#
# The guard sweep's cadence moved from every merge to a daily schedule, and what
# makes a daily schedule cheap is that each shard skips its own expensive steps
# when the tree it is looking at was already proved. That shard still RUNS: it
# checks out, sets up Python, asks the gate, and exits successful in about forty
# seconds.
#
# Forty seconds is a real duration and a positive one, so the existing shape
# check that catches a skipped job lets it straight into the series. The series
# then holds two populations, roughly 1,400s when there was something to prove
# and roughly 40s when there was not, and the halves it compares are decided by
# how many quiet days happened to fall on each side. That is a warning fired by
# the merge pattern rather than by anything about the job, and this is the one
# instrument #991 and #992 are judged by, so poisoning it would take the
# measurement away from the two issues it was built for (L36, L102).


def _run(*jobs: dict) -> dict:
    return {"jobs": list(jobs)}


def _job(name: str, seconds: int, *steps: tuple[str, str]) -> dict:
    return {"name": name,
            "started_at": "2026-08-30T07:00:00Z",
            "completed_at": f"2026-08-30T07:{seconds // 60:02d}:{seconds % 60:02d}Z",
            "steps": [{"name": n, "conclusion": c} for n, c in steps]}


def test_a_shard_that_skipped_its_proof_contributes_no_duration():
    series = job_durations(
        [_run(_job("full (1)", 40, (PROOF_STEP, "skipped")))],
        work_step=PROOF_STEP)
    assert series == {}, (
        "a shard that had nothing to prove is in the series, so the guard "
        "sweep's duration now measures how many quiet days fell in each half")


def test_a_shard_that_did_prove_something_is_measured_as_before():
    series = job_durations(
        [_run(_job("full (1)", 1400, (PROOF_STEP, "success")))],
        work_step=PROOF_STEP)
    assert series == {"full (1)": [1400.0]}


def test_a_shard_whose_proof_went_red_still_counts_as_time_spent():
    """It did the work; the work failed. Dropping it would hide a job that got
    slower until it went red, which is the direction that matters most."""
    series = job_durations(
        [_run(_job("full (2)", 1700, (PROOF_STEP, "failure")))],
        work_step=PROOF_STEP)
    assert series == {"full (2)": [1700.0]}


def test_a_job_with_no_step_by_that_name_is_left_alone():
    """The rule is about jobs that HAVE the named work and did not do it. Every
    other job in every other workflow reads exactly as it did, which is what
    lets one step name be passed for all three workflows rather than a per
    workflow table nobody maintains (L96)."""
    series = job_durations(
        [_run(_job("swift-unit", 655, ("Run the Swift unit tests", "success")))],
        work_step=PROOF_STEP)
    assert series == {"swift-unit": [655.0]}


def test_without_a_work_step_nothing_is_dropped_for_it():
    """The default has to leave every existing caller reading what it read
    before, or this fix silently empties a series somewhere else."""
    series = job_durations([_run(_job("full (1)", 40, (PROOF_STEP, "skipped")))])
    assert series == {"full (1)": [40.0]}
