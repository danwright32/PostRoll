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
from tools.check_tree_already_checked import WORK_STEP
from source_text import without_prose


def _series(older: list[float], recent: list[float]) -> list[float]:
    """A window in the order the API returns it: newest first."""
    return list(reversed(older + recent))


def test_a_job_that_got_materially_slower_is_reported():
    """The reading the issue was written from: 476s becoming 530s.

    Carrying a work count since #1041. The verdict SLOWER now means the job
    costs more PER UNIT of work, so a fixture without one would be asserting
    about a reading the tool no longer makes.
    """
    verdict = drift_of("swift-unit", _series([470, 476, 480, 478],
                                             [525, 530, 535, 532]),
                       work=[2600] * 8)

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
                                             [410, 405, 415, 408]),
                       work=[2600] * 8)

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
    # As code, not as prose (#1074): this workflow explains the series in
    # comments that name the tool and the step, so a raw read is answered
    # by the explanation of something that has been deleted (L103, L135).
    workflow = without_prose(GUARDS)

    assert "check_job_durations.py" in workflow, (
        "nothing runs the duration series, so it can only ever be read by "
        "somebody who already suspects the answer")


def test_the_duration_check_reads_the_workflow_on_the_critical_path():
    """swift.yml is the job the drift was measured on, so it must be covered.

    A series that happens to watch the cheap workflows while the expensive one
    drifts is the instrument reporting green about the wrong thing (L320).
    """
    # As code, not as prose (#1074): this workflow explains the series in
    # comments that name the tool and the step, so a raw read is answered
    # by the explanation of something that has been deleted (L103, L135).
    workflow = without_prose(GUARDS)
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


# ── the same rule, for the jobs #990's gate can skip ─────────────────────────
#
# #990 gives `python`, `macos`, `swift-unit` and `reference-frames` the same
# shape the sweep has: on a push to main whose tree a green pull request already
# carried, their expensive steps skip and the job exits successful in well under
# a minute. That is the identical trap, in three more workflows, and this series
# is read for all of them.
#
# One shared step name across every gated job rather than a name per workflow.
# `did_its_work` already leaves a job carrying none of the names alone, so the
# whole set can be passed everywhere and each workflow is only affected by the
# name its own jobs actually carry (L96).

def test_a_gated_job_that_skipped_its_work_contributes_no_duration():
    series = job_durations(
        [_run(_job("swift-unit", 44, (WORK_STEP, "skipped")))],
        work_step=(PROOF_STEP, WORK_STEP))
    assert series == {}, (
        "a job whose tree was already proved on its pull request is in the "
        "series, so swift.yml's durations now measure the merge pattern")


def test_a_gated_job_that_did_its_work_is_measured_as_before():
    series = job_durations(
        [_run(_job("swift-unit", 434, (WORK_STEP, "success")))],
        work_step=(PROOF_STEP, WORK_STEP))
    assert series == {"swift-unit": [434.0]}


def test_one_name_being_present_does_not_drop_a_job_carrying_the_other():
    """Both names are passed everywhere, so a sweep shard must still be judged
    by its own step and a gated job by its own, with neither answering for the
    other (L70)."""
    series = job_durations(
        [_run(_job("full (1)", 1400, (PROOF_STEP, "success")),
              _job("swift-unit", 44, (WORK_STEP, "skipped")))],
        work_step=(PROOF_STEP, WORK_STEP))
    assert series == {"full (1)": [1400.0]}


def test_a_single_step_name_still_works_as_a_bare_string():
    """Every existing caller passes one name, and this must not become a
    per-character scan of it: a string is iterable, so a change that forgot
    this would compare each step name against 'R', 'e', '-' and match nothing,
    silently restoring the population the rule exists to drop."""
    series = job_durations(
        [_run(_job("full (1)", 40, (PROOF_STEP, "skipped")))],
        work_step=PROOF_STEP)
    assert series == {}


# ── a rate, not a total (#1041, #1039) ───────────────────────────────────────
#
# `drift_of` compared the median of a job's recent half against its older half.
# For a job whose workload is fixed that reading means what it says. For a job
# whose cost depends on the CONTENT of the change it runs against it does not,
# and the tool presented both with the same confidence.
#
# Measured on 2026-08-30, within an hour of the tool landing: it reported
# `changed: faster, 227s to 50s (-78%)` for the per-pull-request guard job,
# which proves only the entries a diff touches. Reading all 21 successful runs
# instead gives median 181s against the 154s recorded in #997. The job had not
# got faster at all; the recent window happened to hold small pull requests. That
# reading was used to argue #997 was no longer worth doing, which was wrong.
#
# So the series is a RATE where a divisor can be had, and says so plainly where
# it cannot, because a verdict nothing can normalise is not the same as a steady
# one (L98).

def test_a_job_given_more_work_for_proportionally_more_time_is_steady():
    """The case that produced the false reading, in reverse."""
    verdict = drift_of("python",
                       seconds=[300, 300, 300, 100, 100, 100],
                       work=[30, 30, 30, 10, 10, 10])
    assert verdict.state is Drift.STEADY, verdict.message
    assert "per" in verdict.message, verdict.message


def test_a_job_doing_the_same_work_more_slowly_is_still_reported():
    """Normalising must not blunt the thing this exists to catch."""
    verdict = drift_of("swift-unit",
                       seconds=[600, 600, 600, 400, 400, 400],
                       work=[2600, 2600, 2600, 2600, 2600, 2600])
    assert verdict.state is Drift.SLOWER, verdict.message


def test_a_job_that_got_faster_at_the_same_work_is_reported_as_faster():
    verdict = drift_of("swift-unit",
                       seconds=[400, 400, 400, 600, 600, 600],
                       work=[2600] * 6)
    assert verdict.state is Drift.FASTER, verdict.message


def test_the_normalised_message_names_the_unit_and_the_counts():
    """A reader has to be able to see what it divided by (L11)."""
    message = drift_of("swift-unit",
                       seconds=[600] * 3 + [400] * 3,
                       work=[2600] * 6).message
    assert "2600" in message, message


def test_a_material_move_with_no_divisor_is_not_called_slower():
    """The exact defect: a bare comparison presented with the confidence of a
    normalised one. It is reported, distinctly, and not as a regression."""
    verdict = drift_of("mystery-job", seconds=[300, 300, 300, 100, 100, 100])
    assert verdict.state is Drift.NOT_NORMALISED, verdict.message
    assert not verdict.state.is_alarming
    assert "workload" in verdict.message, verdict.message


def test_a_partial_work_series_does_not_normalise_half_the_window():
    """Some runs measured and some not is not a rate, and quietly dropping the
    unmeasured ones would shift which runs fall in each half (L288)."""
    verdict = drift_of("python",
                       seconds=[300, 300, 300, 100, 100, 100],
                       work=[30, 30, None, 10, 10, 10])
    assert verdict.state is Drift.NOT_NORMALISED, verdict.message


def test_a_zero_work_count_does_not_normalise():
    """A job that did nothing has no rate, and dividing by it would report an
    infinite one."""
    verdict = drift_of("python",
                       seconds=[300, 300, 300, 100, 100, 100],
                       work=[30, 30, 30, 0, 10, 10])
    assert verdict.state is Drift.NOT_NORMALISED, verdict.message


def test_an_unnormalised_move_inside_the_band_is_still_steady():
    """Only a MATERIAL move needs the caveat; a quiet one says nothing either
    way and does not need a second sentence about workload."""
    verdict = drift_of("mystery-job", seconds=[101, 100, 100, 100, 100, 100])
    assert verdict.state is Drift.STEADY, verdict.message


# ── how each job says how much work it did ───────────────────────────────────

def test_each_job_family_has_its_count_read_from_its_own_log():
    from tools.check_job_durations import work_done
    assert work_done("Swift: 2622 tests", "swift-unit") == 2622
    assert work_done("4410 passed, 106 skipped in 129.67s", "python") == 4410
    assert work_done("40 passed in 12.0s", "reference-frames (goldens)") == 40


def test_the_last_count_in_a_log_is_the_one_that_counts():
    """A log holds every line the job printed, including earlier partial runs
    and the pytest header. The final summary is the answer."""
    from tools.check_job_durations import work_done
    assert work_done("10 passed in 1s\nand later\n4410 passed in 129s",
                     "python") == 4410


def test_a_job_with_no_known_count_reads_as_None_rather_than_zero():
    """Zero is a measurement of a job that did nothing, and this is not one."""
    from tools.check_job_durations import work_done
    assert work_done("nothing recognisable here", "python") is None
    assert work_done("4410 passed", "some-job-nobody-taught-this-about") is None


def test_the_guard_jobs_are_still_never_normalised_by_entry_count():
    """A count of items is not a measure of work when the items differ (L63).

    This is the half of the old rule that survives #1090. Their logs do report
    `N guards checked` and it is still deliberately not read: measured over the
    whole registry on 2026-08-31, the per-entry cost ran from 0.32s to 137.8s,
    a factor of 431, because a Swift entry rebuilds the app at about 24s and a
    Python one is usually under a second. Normalising by a count would hand a
    bare comparison the confidence of a real one, which is the exact defect
    #1041 exists to remove.
    """
    from tools.check_job_durations import work_done

    assert work_done("29 guards checked, 29 killed", "changed") is None
    assert work_done("29 guards checked, 29 killed", "full (2)") is None


def test_the_guard_jobs_are_normalised_by_recorded_entry_cost():
    """What replaced NOT_NORMALISED (#1090).

    The guard jobs now print the RECORDED cost of the entries they proved, so a
    diff selecting more expensive entries raises both halves of the rate and
    leaves it where it was, while a slower runner raises only the duration.
    """
    from tools.check_job_durations import WORK_PATTERNS, work_done

    assert "changed" in WORK_PATTERNS
    assert "full" in WORK_PATTERNS
    line = "guard work: 12345 recorded entry-ms over 44 entries, 44 of them measured"
    assert work_done(line, "changed") == 12345
    assert work_done(line, "full (2)") == 12345


def test_a_guard_job_that_could_not_price_its_work_is_not_normalised():
    """The record can be unreadable, and then there is no divisor.

    NOT_NORMALISED is still the honest answer there. A zero divisor is not a
    measurement of a job that did nothing, it is the absence of one, and the two
    must not read alike (L11).
    """
    from tools.check_job_durations import work_done

    unmeasured = ("guard work: unmeasured, because the cost record could not "
                  "answer: no such file")
    # Through the real reader, so this asserts about the line the tool prints
    # rather than about a None written here (L52).
    work = [work_done(unmeasured, "changed")] * 6
    assert drift_of("changed", seconds=[300, 300, 300, 100, 100, 100],
                    work=work).state is Drift.NOT_NORMALISED


# ── fetching the counts, and what happens when a log will not come ───────────

def _job_with(name: str, seconds: int, job_id: int, *steps: tuple[str, str]) -> dict:
    return {**_job(name, seconds, *steps), "id": job_id}


def test_each_job_is_paired_with_its_own_log_s_count():
    from tools.check_job_durations import work_series

    logs = {901: "Swift: 2600 tests", 902: "Swift: 2610 tests"}
    series = work_series(
        [_run(_job_with("swift-unit", 400, 901)),
         _run(_job_with("swift-unit", 410, 902))],
        read_log=lambda path: logs[int(path.split("/jobs/")[1].split("/")[0])])

    assert series == {"swift-unit": [2600, 2610]}


def test_the_counts_line_up_with_the_durations_run_for_run():
    """The rate is a division of one series by the other, so a job dropped from
    one and kept in the other would pair a duration with another run's count
    and every rate would be wrong invisibly (L228)."""
    from tools.check_job_durations import work_series

    runs = [_run(_job_with("swift-unit", 400, 901)),
            # skipped by shape: completed before it started
            _run({"name": "swift-unit", "id": 902, "steps": [],
                  "started_at": "2026-08-30T13:19:13Z",
                  "completed_at": "2026-08-30T13:19:12Z"}),
            _run(_job_with("swift-unit", 420, 903))]
    logs = {901: "Swift: 2600 tests", 902: "Swift: 1 tests",
            903: "Swift: 2610 tests"}

    durations = job_durations(runs)
    counts = work_series(runs, read_log=lambda p: logs[
        int(p.split("/jobs/")[1].split("/")[0])])

    assert len(durations["swift-unit"]) == len(counts["swift-unit"])
    assert counts["swift-unit"] == [2600, 2610], (
        "the skipped run contributed a count while contributing no duration, "
        "so every pair after it is a duration matched to the wrong run's count")


def test_a_log_that_will_not_download_leaves_the_job_unnormalised():
    """Not an exception, and not a zero. A log that will not come is a run whose
    work count is unknown, and unknown is already a first class answer here: it
    lands the job in NOT_NORMALISED rather than taking the whole check down
    (L73), and it is never scored as a measurement (L11)."""
    from tools.check_job_durations import work_series

    def refuses(path):
        raise RuntimeError("gh fell over")

    series = work_series([_run(_job_with("swift-unit", 400, 901))],
                         read_log=refuses)

    assert series == {"swift-unit": [None]}
    assert drift_of("swift-unit", [300, 300, 300, 100, 100, 100],
                    work=[None] * 6).state is Drift.NOT_NORMALISED


def test_a_job_with_no_known_pattern_is_never_downloaded():
    """A log is a megabyte. Fetching one for a job whose count could not be read
    anyway is a megabyte spent to learn nothing."""
    from tools.check_job_durations import work_series

    asked: list[str] = []

    def record(path):
        asked.append(path)
        return "4410 passed"

    series = work_series([_run(_job_with("hand-check-reminder", 7, 901))],
                         read_log=record)

    assert series == {"hand-check-reminder": [None]}
    assert asked == [], f"a log was downloaded for a job with no pattern: {asked}"


def test_the_log_is_asked_for_by_the_job_s_own_id():
    from tools.check_job_durations import job_log

    asked: list[str] = []
    job_log(4242, read=lambda path: asked.append(path) or "")

    assert asked == ["repos/{owner}/{repo}/actions/jobs/4242/logs"]


# ── a test that fails only sometimes (#1060) ─────────────────────────────────
#
# CI runs each commit once, so an intermittent failure is invisible to it: one
# red run reads as a real failure and a re-push reads as a fix. Nothing recorded
# how often a given test did that, so the cost was paid over and over as re-runs
# and never attributed to anything.
#
# On 2026-08-30 `CheckoutRevisionTests` was failing roughly one local run in
# three after #992 made the Swift suite parallel, and it was found only by
# running the suite eight times by hand while working on something else. It
# reached main and sat there. The defect was real (blocking waits on a bounded
# dispatch pool) and is fixed, but nothing would have surfaced the pattern.
#
# The logs are already being read for the work counts, so the failures in them
# are free. A test that failed in SOME runs of the window and not others is a
# flake; one that failed in all of them is simply broken and is somebody's
# current problem rather than a pattern worth ranking (L293).

def test_a_test_that_failed_once_in_a_window_is_named():
    from tools.check_job_durations import flakes

    found = flakes({"swift-unit": [{"A"}, set(), set(), set(), set(), set()]})
    assert found == [("swift-unit", "A", 1, 6)]


def test_a_test_that_failed_every_time_is_not_a_flake():
    """It is broken, not intermittent, and it is already somebody's problem.
    Ranking it here would bury the intermittent ones it exists to surface."""
    from tools.check_job_durations import flakes

    assert flakes({"swift-unit": [{"A"}] * 6}) == []


def test_the_worst_offender_comes_first():
    """Ranked, because the point is to know which one to fix (L293)."""
    from tools.check_job_durations import flakes

    found = flakes({"python": [{"A", "B"}, {"B"}, {"B"}, set(), set(), set()]})
    assert [name for _job, name, _n, _of in found] == ["B", "A"]


def test_a_window_with_no_failures_at_all_names_nobody():
    from tools.check_job_durations import flakes

    assert flakes({"swift-unit": [set()] * 6}) == []


def test_a_window_too_short_to_tell_names_nobody():
    """One run holding one failure is not evidence of intermittency, it is a
    single red run, which is what CI already shows (L98)."""
    from tools.check_job_durations import flakes

    assert flakes({"swift-unit": [{"A"}]}) == []


# ── reading the failures out of a log ────────────────────────────────────────

def test_a_failed_swift_test_is_read_from_its_own_line():
    from tools.check_job_durations import failed_tests

    log = ("Test case 'CheckoutRevisionTests.testReadsTheRevision()' failed on "
           "'My Mac - xctest (123)' (5.001 seconds)\n"
           "Test case 'OtherTests.testFine()' passed on 'My Mac' (0.1 seconds)\n")
    assert failed_tests(log, "swift-unit") == {
        "CheckoutRevisionTests.testReadsTheRevision()"}


def test_a_failed_python_test_is_read_from_its_own_line():
    from tools.check_job_durations import failed_tests

    log = ("FAILED tests/test_thing.py::test_one - AssertionError: nope\n"
           "FAILED tests/test_thing.py::test_two[case]\n"
           "4410 passed, 2 failed\n")
    assert failed_tests(log, "python") == {
        "tests/test_thing.py::test_one", "tests/test_thing.py::test_two[case]"}


def test_a_green_log_reports_no_failures():
    from tools.check_job_durations import failed_tests

    assert failed_tests("Swift: 2622 tests\nall good\n", "swift-unit") == set()


def test_a_job_this_cannot_read_reports_nothing_rather_than_guessing():
    """Distinct from a green run in the caller, which requires a run to have
    been READ before it counts one (L98)."""
    from tools.check_job_durations import failed_tests

    assert failed_tests("FAILED tests/x.py::t", "some-job-nobody-taught") == set()


def test_the_log_is_downloaded_once_per_job_not_once_per_answer():
    """Both answers come out of the same text, and the download is the only
    expensive part of this whole check."""
    from tools.check_job_durations import read_logs

    asked: list[str] = []

    def record(path):
        asked.append(path)
        return "Swift: 2600 tests"

    counts, failures = read_logs([_run(_job_with("swift-unit", 400, 901))],
                                 read_log=record)

    assert len(asked) == 1, f"the log was fetched {len(asked)} times: {asked}"
    assert counts == {"swift-unit": [2600]}
    assert failures == {"swift-unit": [set()]}


def test_a_log_that_could_not_be_read_adds_no_run_to_the_flake_window():
    """An empty set of failures is the same shape as a run that passed
    everything, so counting one would grow the denominator and make a real
    flake look rarer than it is (L98)."""
    from tools.check_job_durations import read_logs

    def refuses(path):
        raise RuntimeError("gh fell over")

    counts, failures = read_logs([_run(_job_with("swift-unit", 400, 901))],
                                 read_log=refuses)

    assert counts == {"swift-unit": [None]}
    assert failures == {}, (
        "a run nobody could read was counted as a run in which nothing failed")
