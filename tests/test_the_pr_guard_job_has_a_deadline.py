"""The per-pull-request guard job stops itself, and says who that blocks (#1086).

The `full` sweep passes `--deadline-seconds 1800` so a shard that runs out of
time reports WHICH entries went unproven, rather than being killed by
`timeout-minutes` and reporting CANCELLED, which is what a superseded run
reports too (L11). The `changed` job passed no deadline at all: a wide diff
either finished or was killed 45 minutes later with nothing saying what it
reached.

Measured over 2026-08-30 and 31, this job was the sole thing holding FIVE
separate merges, for 15 to 19 minutes each, with every other check already
green, and #1072 waited 1,140s on it alone.

The number is chosen from the distribution of the job's own past runs, and those
readings live in `tests/fixtures/changed_job_timing.json` so the choice can be
re-measured rather than believed (L316). Re-measure with
`venv/bin/python tools/measure_changed_job.py`.
"""

from __future__ import annotations

import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
from tools import measure_changed_job as measure  # noqa: E402
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "guards.yml"
RECORD = REPO_ROOT / "tests" / "fixtures" / "changed_job_timing.json"

#: A run proving this many entries or more is a WIDE one, which is the case the
#: deadline exists for (#1351). The issue's own boundary, and it is also where
#: the readings stop being setup: every reading under five sits in the first
#: minute.
WIDE_AT = 5
#: Below this the p90 the deadline is chosen against is a single reading.
FEWEST_WIDE = 10


def measured() -> dict:
    assert RECORD.exists(), (
        f"{RECORD.relative_to(REPO_ROOT)} is missing, so nothing says where the "
        "deadline below came from and every check here is against a number "
        "nobody measured")
    found = json.loads(RECORD.read_text(encoding="utf-8"))
    assert found.get("seconds"), (
        "the record holds no readings, so the checks below compare the deadline "
        "against an empty distribution and pass whatever it is (L98)")
    return found


def workflow() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def declared_deadline() -> int:
    """What the `changed` job actually passes, read out of the workflow.

    Read rather than assumed, because a deadline in a record and no deadline in
    the workflow is exactly the state this issue found: built is not wired (L3).
    """
    found = re.search(r"check_guards\.py --changed --deadline-seconds (\d+)",
                      workflow())
    assert found, (
        "the `changed` job no longer passes --deadline-seconds, so a wide diff "
        "is back to being killed by timeout-minutes with nothing saying what it "
        "reached, and a killed job reports CANCELLED, which is what a superseded "
        "run reports too (L11)")
    return int(found.group(1))


def job_timeout_seconds() -> int:
    """The `changed` job's own cap, in seconds."""
    block = workflow().split("  changed:", 1)[1].split("\n  full:", 1)[0]
    found = re.search(r"timeout-minutes: (\d+)", block)
    assert found, "the `changed` job carries no timeout-minutes at all (L313)"
    return int(found.group(1)) * 60


def percentile(seconds: list[int], share: float) -> int:
    ordered = sorted(seconds)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))]


def working_seconds() -> list[int]:
    """The readings of runs that actually PROVED something (#1351).

    A run the diff affected no entry of returns in setup time and its duration
    measures the runner rather than the job: measured on 2026-09-05, 15 of 94
    readings proved nothing, and those 15 have a median of 43s against 75s for
    the rest. Counting them drags every percentile below down, and a run that
    did no work is indistinguishable from a genuinely fast one once only its
    duration is kept (L331).
    """
    found = measured()
    readings = found.get("readings")
    assert readings, (
        "the record holds no per-reading entry counts, so nothing can tell a "
        "run that proved 40 guards from one that proved none, and the "
        "percentiles below are over a sample nobody can describe. Re-measure "
        f"with `{found.get('re_measure_with', 'tools/measure_changed_job.py')} "
        "--write`.")
    working = [int(r["seconds"]) for r in readings if r.get("entries")]
    assert working, (
        "every reading in the record proved nothing, so the sample measures "
        "the runner's setup and not this job at all")
    return working


# ── the deadline is wired, and it is the record's number ─────────────────────

def test_the_changed_job_passes_a_deadline():
    assert declared_deadline() > 0


def test_the_workflow_and_the_record_name_the_same_deadline():
    """Two copies of one number, held equal rather than trusted (L41).

    The record is where the choice is explained; the workflow is what actually
    happens. If they drift, the explanation describes a deadline nothing uses.
    """
    assert declared_deadline() == measured()["deadline_seconds"], (
        f"guards.yml passes {declared_deadline()}s and "
        f"{RECORD.name} says {measured()['deadline_seconds']}s was chosen")


# ── it is the deadline that fires, not the runner's cap ──────────────────────

def test_the_deadline_is_well_under_the_job_s_own_cap():
    """Whichever fires first decides what is reported, and only the deadline can
    say which entries went unproven."""
    deadline, cap = declared_deadline(), job_timeout_seconds()
    assert deadline < cap, (
        f"the deadline is {deadline}s and the job is capped at {cap}s, so the "
        "cap fires first and reports CANCELLED")
    # Ten times the job's measured setup, not the five minutes this used to
    # claim. Read off 11 successful runs on 2026-09-04: checkout 4s, Prepare the
    # Mac build 4s, Set up Python 3s, dependencies 5s, ffmpeg 6s, 24s in total
    # and 31s at worst. The five minute figure predates the shared
    # prepare-mac-build action and its caches (#1249), and it is the premise
    # that made raising the deadline look impossible (L316, #1280).
    setup_seconds = 31
    assert cap - deadline >= setup_seconds * 10, (
        f"only {cap - deadline}s separates the deadline from the cap, and this "
        f"job's setup has been measured at {setup_seconds}s at worst, so the "
        "margin is under ten times it and a slow setup could put the cap first")


# ── it is sized from the distribution, not picked round (L172) ───────────────

def test_the_deadline_does_not_fire_on_an_ordinary_run():
    """A check that fires on ordinary runs is one that gets turned off (L36)."""
    seconds = working_seconds()
    p75 = percentile(seconds, 0.75)
    assert declared_deadline() > p75, (
        f"the deadline is {declared_deadline()}s and three runs in four finish "
        f"within {p75}s, so this would fire on ordinary pull requests")


def test_the_deadline_can_actually_fire():
    """A limit nothing has ever crossed is a limit nobody has measured (L182).

    The runs above it are the 15 to 36 minute ones this issue is about.
    """
    seconds = working_seconds()
    over = [s for s in seconds if s >= declared_deadline()]
    assert over, (
        f"no recorded run of this job reached {declared_deadline()}s, so the "
        "deadline has never been in reach and protects nothing")
    assert len(over) / len(seconds) < 0.2, (
        f"{len(over)} of {len(seconds)} recorded runs are at or over the "
        "deadline, which is not a tail any more: either the job has got much "
        "slower or the deadline is too tight")


def test_the_deadline_is_not_inside_the_dense_middle():
    """A threshold sitting where the readings are crowded turns the count it
    produces into noise: a small uniform shift carries many runs across it at
    once and reads as a sudden regression (L172).

    So it must sit in a real gap. The nearest recorded run on either side has to
    be further away than the median run is long.
    """
    deadline = declared_deadline()
    seconds = sorted(working_seconds())
    below = max((s for s in seconds if s < deadline), default=0)
    above = min((s for s in seconds if s >= deadline), default=deadline * 10)
    gap = above - below
    assert gap >= statistics.median(seconds), (
        f"the deadline at {deadline}s sits between recorded runs of {below}s and "
        f"{above}s, a gap of {gap}s, which is narrower than the median run "
        f"({statistics.median(seconds):.0f}s). Pick a number in a real gap.")


# ── the sample says what it is made of (#1351) ───────────────────────────────

def test_every_reading_says_how_many_entries_that_run_proved():
    """A sample skewed toward changes that touch little Swift reads exactly like
    a representative one, and the record used to carry that as a sentence
    somebody wrote, which nothing checks and nothing expires (L27, L316)."""
    readings = measured().get("readings")
    assert readings, "the record carries no readings, so its composition is prose"
    for reading in readings:
        assert "seconds" in reading and "entries" in reading, (
            f"a reading with no entry count at all: {reading}. Unreadable is "
            "recorded as null, which is a different thing from missing.")


def test_the_sample_holds_enough_wide_runs_to_size_a_tail_from():
    """The deadline exists for the wide diffs, so a sample of narrow ones cannot
    justify it however many readings it has.

    Ten, because below that the p90 the deadline is chosen against IS a single
    reading, and one reading is a story rather than a distribution. Measured on
    2026-09-05: 60 of 94 readings proved five entries or more.
    """
    readings = measured()["readings"]
    wide = [r for r in readings if (r.get("entries") or 0) >= WIDE_AT]
    assert len(wide) >= FEWEST_WIDE, (
        f"only {len(wide)} of {len(readings)} readings proved {WIDE_AT} entries "
        f"or more, which is fewer than the {FEWEST_WIDE} it takes for the tail "
        "to be a distribution rather than one run. The deadline is about wide "
        "diffs, so re-measure after a stretch of app work rather than "
        "justifying it from this.")


def test_the_run_at_or_over_the_deadline_is_a_wide_one():
    """What the deadline is FOR, asserted rather than assumed. A narrow diff
    taking longer than the deadline would mean the cost is not where this
    thinks it is, and the number was chosen against the wrong variable (L209).
    """
    readings = measured()["readings"]
    slow = [r for r in readings if int(r["seconds"]) >= declared_deadline()]
    assert slow, "no reading reaches the deadline, which the rule above covers"
    narrow = [r for r in slow if r.get("entries") is not None
              and r["entries"] < WIDE_AT]
    assert not narrow, (
        f"these runs reached the deadline while proving fewer than {WIDE_AT} "
        f"entries: {narrow}. The deadline is sized on how much a run proves, so "
        "either the cost is not in the entries or one of these was starved by "
        "the runner.")


# ── the recorder that fills it (#1351) ──────────────────────────────────────


class FakeRuns:
    """The two API calls the recorder makes, from replies shaped like GitHub's."""

    def __init__(self, jobs: list[dict]) -> None:
        self.jobs = jobs

    def __call__(self, path: str) -> dict:
        if "/actions/workflows/" in path:
            return {"workflow_runs": [{"id": 1}]}
        return {"jobs": self.jobs}


def a_job(job_id: int, seconds: int, *, name: str = "changed",
          conclusion: str = "success") -> dict:
    return {"id": job_id, "name": name, "conclusion": conclusion,
            "started_at": "2026-09-05T00:00:00Z",
            "completed_at": f"2026-09-05T00:{seconds // 60:02d}:{seconds % 60:02d}Z"}


def test_a_reading_carries_how_many_entries_that_run_proved():
    found = measure.readings(
        ask=FakeRuns([a_job(7, 300)]),
        log=lambda _id: "--changed: 34 of 645 entries affected by the diff")

    assert [(r.seconds, r.entries) for r in found] == [(300, 34)]


def test_a_log_that_cannot_be_read_records_nothing_rather_than_zero():
    """GitHub keeps job logs for 90 days. A run whose log has aged out is a run
    nobody can describe, and recording it as having proved none of them would
    count the retention window as evidence about the work (L11)."""
    found = measure.readings(ask=FakeRuns([a_job(7, 300)]), log=lambda _id: None)

    assert found[0].entries is None


def test_a_run_that_proved_nothing_is_a_measured_zero():
    """Said in so many words by the job itself, so it is a reading rather than
    an absence: these are the ones that return in setup time."""
    found = measure.readings(
        ask=FakeRuns([a_job(7, 43)]),
        log=lambda _id: "no registered guard is affected by this diff, so "
                        "nothing was verified")

    assert found[0].entries == 0


def test_the_composition_counts_the_four_kinds_apart():
    """One percentage would hide which of them moved."""
    made_of = measure.composition([
        measure.Reading(seconds=43, entries=0),
        measure.Reading(seconds=90, entries=2),
        measure.Reading(seconds=800, entries=34),
        measure.Reading(seconds=120, entries=None),
    ], wide_at=WIDE_AT)

    assert made_of["proved_nothing"] == 1
    assert made_of["narrow"] == 1
    assert made_of["wide"] == 1
    assert made_of["unreadable"] == 1


def test_a_job_that_is_not_this_one_is_not_a_reading():
    found = measure.readings(
        ask=FakeRuns([a_job(7, 300, name="full"), a_job(8, 60)]),
        log=lambda _id: "--changed: 6 of 645 entries affected")

    assert [(r.seconds, r.entries) for r in found] == [(60, 6)]


def test_a_run_that_was_cancelled_is_not_a_reading():
    """Its duration measures when somebody pushed again (L331)."""
    found = measure.readings(
        ask=FakeRuns([a_job(7, 300, conclusion="cancelled"), a_job(8, 60)]),
        log=lambda _id: "--changed: 6 of 645 entries affected")

    assert [r.seconds for r in found] == [60]


class FakePytest:
    """Stands in for the run of the deadline rules, recording what it was told
    to run."""

    def __init__(self, *, code: int, output: str = "") -> None:
        self.code = code
        self.output = output
        self.ran: list[list[str]] = []

    def __call__(self, argv, **_kwargs):
        self.ran.append(list(argv))
        return subprocess.CompletedProcess(argv, self.code, self.output, "")


def test_a_green_run_of_the_rules_names_nothing():
    assert measure.deadline_rules_failing(run=FakePytest(code=0)) == []


def test_the_rules_that_failed_are_named_one_by_one():
    """The point of running them: the re-measure says what work it created,
    rather than printing a warning to go and look."""
    output = ("FAILED tests/test_the_pr_guard_job_has_a_deadline.py::"
              "test_the_deadline_can_actually_fire - assert 0\n"
              "FAILED tests/test_the_pr_guard_job_has_a_deadline.py::"
              "test_the_deadline_is_not_inside_the_dense_middle - assert 12\n")

    assert measure.deadline_rules_failing(run=FakePytest(code=1, output=output)) == [
        "test_the_deadline_can_actually_fire",
        "test_the_deadline_is_not_inside_the_dense_middle",
    ]


def test_a_run_that_failed_without_naming_a_test_says_so_rather_than_nothing():
    """A collection error exits non zero and names no test. Reporting that as
    an empty list would read as the rules passing, which is the one thing it
    does not mean (L98)."""
    named = measure.deadline_rules_failing(run=FakePytest(code=2, output="ERROR"))

    assert len(named) == 1
    assert "run it yourself" in named[0]
