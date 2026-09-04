#!/usr/bin/env python3
"""Say when a CI job's duration has moved, before an audit has to find it (#1019).

Nothing in this repository read its own duration over time. Measured from the
Actions API for the week of 2026-08-22 to 08-29: the Swift test step's median
went from 476s over the first eight runs to 530s over the last eight, and the
guard sweep drifted to within a few entries of its 1,800s deadline and went red
four times before anybody measured the distance (#989).

This is the instrument #991 and #992 are judged by, which is why it lands ahead
of them: a change whose whole purpose is to move this number needs a reading of
the number from before the change (L309).

## It warns, it does not gate

A job getting slower does not make the change being merged wrong, and failing a
run for it would stop unrelated work for an unrelated reason, which is how a
check teaches everyone to bypass it (L36). Every state exits 0. The visibility
is the warning annotation and the job summary, exactly as
`tools/check_guard_sweep_freshness.py` decided for the same reason.

## Why it compares halves rather than the latest run

Comparing the newest run against the spread of the ones before it fires on
ordinary noise, because a single run's duration swings with whichever runner it
landed on. A threshold set where that variation lives produces a warning nobody
reads (L172).

Comparing one half of the window against the other is what actually found the
drift above, so it is what this does: the same reading the issue was written
from, rather than a different one that is easier to compute.
"""

from __future__ import annotations

import argparse
import enum
import json
import os
import re
import statistics
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Iterable
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.guard_sweep_history import PROOF_STEP  # noqa: E402
from tools.check_tree_already_checked import WORK_STEP  # noqa: E402

from tools.wait_for_checks import GhUnusable, gh_json  # noqa: E402

#: Every step name a gate in this repository can skip. Passed for every
#: workflow: `did_its_work` leaves a job carrying none of them alone, so each
#: workflow is affected only by the name its own jobs actually have, and there
#: is no per-workflow table to keep in step with the workflows (L96).
WORK_STEPS = (PROOF_STEP, WORK_STEP)

#: How far the two halves' medians must differ before it is worth saying.
#:
#: Derived from the two shifts the issue measured rather than chosen for feeling
#: about right. The Swift leg moved 11.3% in a week and is the case this exists
#: to catch; the Python leg moved 3.8% over the same window and is presented
#: there as ordinary. 8% sits between them with room on both sides, so the
#: reading that prompted the issue fires and the one it treats as normal does
#: not (L172).
MATERIAL_SHIFT = 0.08

#: Where a job's own MEASURED run to run noise is recorded, when it has one.
#:
#: The 8% above was derived from two week-long shifts, which is a reasonable way
#: to pick a bar and is not the same as measuring what the runner does. On
#: 2026-09-04 that measurement was taken for the Swift suite: two runs of
#: IDENTICAL code at commit 8ea7b53448cf came out at 156.1s and 203.7s, 30.5%
#: apart. On that same day this tool reported `swift-unit: faster, -11%`, which
#: is a reading well inside a spread the runner produces on its own (#1329).
#:
#: So a job with a measured floor is judged against that floor rather than
#: against the shared default, and the message says which bar it used. Read from
#: the fixture rather than copied here, so the two cannot drift (L41), and a job
#: with nothing recorded keeps the default rather than being exempted (L96).
NOISE_FLOORS_FILE = "tests/fixtures/ci_job_noise.json"


def _measured_spreads(root=None) -> dict[str, float]:
    """Each job's measured run to run spread, as a fraction, from the record.

    Read rather than restated here, so the numbers and the readings they were
    derived from cannot drift apart (L41). An unreadable record yields nothing,
    which leaves the shared default in place: a floor of zero would make every
    reading material, which is the opposite of what a missing measurement
    should do (L42, L215).
    """
    path = (Path(root) if root is not None else REPO_ROOT) / NOISE_FLOORS_FILE
    try:
        jobs = json.loads(path.read_text())["jobs"]
    except (OSError, ValueError, KeyError, TypeError):
        return {}
    found = {}
    for name, entry in jobs.items():
        try:
            percent = float(entry["spread_percent"]) / 100
        except (KeyError, TypeError, ValueError):
            continue
        if percent > 0:
            found[name] = percent
    return found


def noise_floor(job: str, root=None) -> tuple[float, str] | None:
    """A job's measured run to run spread, and where it was measured, or None.

    None for a job with nothing recorded. A recorded floor that cannot be READ
    is a different fact and gets `unreadable_floor` below, because both fall
    back to the same threshold but only one of them means "nobody has measured
    this job", and a message saying so when a record exists and is broken is a
    claim the check never made (L11).

    Falling back rather than raising is deliberate: a missing or malformed
    record must leave the shared default in place rather than produce a floor
    of zero, which would make every reading material (L42, L215).
    """
    # The FULL job name first. `reference-frames (goldens)` and
    # `reference-frames (legibility)` differ by 7 points, and the matrix suffix
    # is the only thing that tells them apart, so a lookup that stripped it
    # would judge one against the other's noise (L237).
    spreads = _measured_spreads(root=root)
    for key in (job, work_family(job)):
        if key in spreads:
            return spreads[key], f"{NOISE_FLOORS_FILE} {key}"
    return None


def unreadable_floor(job: str, root=None) -> str | None:
    """Where a job's floor SHOULD have been read from, when it could not be.

    Only for a job this repository claims to have measured. A job absent from
    NOISE_FLOORS has nothing to fail to read, and reporting one would be an
    accusation about every job nobody has measured (L11, L93).
    """
    if noise_floor(job, root=root) is not None:
        return None
    # A job with nothing recorded ANYWHERE has no record to fail to read, and
    # `changed` is deliberately one of those: it cannot be dispatched, and the
    # record says why. Only a job the file names but cannot be read for counts.
    path = (Path(root) if root is not None else REPO_ROOT) / NOISE_FLOORS_FILE
    try:
        named = set(json.loads(path.read_text())["jobs"])
    except (OSError, ValueError, KeyError, TypeError):
        # The whole record is unreadable, which is a failure for every job it
        # would have covered. Reported for the ones it is supposed to name.
        return NOISE_FLOORS_FILE if job in _JOBS_EXPECTED_TO_HAVE_A_FLOOR else None
    if job in named or work_family(job) in named:
        return NOISE_FLOORS_FILE
    return None


#: The jobs whose floors have been measured, so a record that stops being
#: readable is reported for them rather than passing as "nobody measured this".
_JOBS_EXPECTED_TO_HAVE_A_FLOOR = frozenset({
    "swift-unit", "macos", "python",
    "reference-frames (goldens)", "reference-frames (legibility)",
})

#: The fewest runs that can be split into two halves and still say anything.
#: Three a side: two would make a median a mean of two numbers, which one slow
#: runner moves as much as a real regression.
MINIMUM_WINDOW = 6


class Drift(enum.Enum):
    STEADY = "steady"
    SLOWER = "slower"
    #: Reported as its own state rather than folded into STEADY. #991 and #992
    #: are changes whose purpose is to make a job faster, and an improvement
    #: reported as "nothing to see" makes this instrument useless for the two
    #: issues it exists to serve (L11).
    FASTER = "faster"
    #: Not enough runs to split. Never STEADY: a window that cannot be read is
    #: not evidence of health, and the two are indistinguishable to anyone
    #: reading a green line (L98).
    NOT_ENOUGH_HISTORY = "not enough history"
    #: The API could not be asked, or answered something unusable. Distinct
    #: from finding nothing, for the same reason.
    UNREADABLE = "unreadable"
    #: The duration moved materially and there is no measure of how much work
    #: the job did, so a job that got SLOWER and one that was given MORE TO DO
    #: are the same reading (#1041). Its own state rather than a SLOWER with a
    #: caveat, because a caveat in the second sentence is read as a hedge on a
    #: verdict already given, and this is not a verdict.
    NOT_NORMALISED = "not normalised"
    #: The shift is smaller than this job's own MEASURED run to run spread, so
    #: nothing can be said about it either way (#1329).
    #:
    #: Its own state rather than a STEADY, because those are different facts and
    #: a reader cannot tell them apart otherwise: STEADY means the job did not
    #: move, this means the instrument cannot see whether it did. Folding them
    #: would make the Swift job report "steady" forever, since its measured
    #: spread is 30.5% and almost nothing clears that (L11, L98).
    INSIDE_THE_NOISE = "inside the noise"

    @property
    def exit_code(self) -> int:
        """Always zero, for every state. This reports; it does not gate.

        One rule over every state rather than one per state, because a check
        where some failure modes gate and others do not leaves the reader
        working out which is which before they can trust any of it.
        """
        return 0

    @property
    def is_alarming(self) -> bool:
        """Whether this deserves a warning annotation rather than a log line.

        NOT_NORMALISED deliberately is not. It is the state that exists because
        an un-normalised comparison was raised with the confidence of a real
        one and used to argue #997 was not worth doing. A warning that cannot
        distinguish a regression from a busy week is exactly the alarm people
        learn to read past (L36), so it is reported and not raised.
        """
        return self in (Drift.SLOWER, Drift.UNREADABLE)


@dataclass(frozen=True)
class Verdict:
    state: Drift
    message: str


#: How each job family says, in its own log, how much work it did (#1039).
#:
#: Read from the log because nothing cheaper carries it: measured on 2026-08-31,
#: a job's step summary and its annotations both come back EMPTY from the checks
#: API, so the log is the only place the count reaches. One is 1.15MB and 0.7s
#: to fetch for the Swift job, timed on the 12 core Mac this tool is normally run
#: from (#1245), so a sixteen run window is about twelve seconds and 18MB
#: once a day, which is affordable and was the thing #1039 asked to be checked
#: before building on it.
#:
#: Keyed on the family, which is the job name before any matrix suffix, so
#: `full (2)` and `reference-frames (goldens)` are covered by one entry each.
#:
#: This IS a hand-kept table and a job missing from it is not silently exempt
#: (L96): it falls to NOT_NORMALISED, which says out loud that its workload
#: could not be measured.
#: The guard proof jobs are deliberately ABSENT, and that is a finding rather
#: than an omission. Their logs do report `N guards checked`, and dividing by it
#: does not normalise them: measured over ten runs on 2026-08-31 the rate ran
#: from 1,174ms to 106,500ms per guard, a factor of 90, on the macos-26 runner
#: those runs used (#1245), because a Swift entry rebuilds the app at about 29s
#: there and a Python one is under a second. A count of
#: ITEMS is not a measure of WORK when the items differ that much (L63, L296),
#: and a divisor that wrong would give a bare comparison the confidence of a
#: normalised one, which is the exact defect #1041 exists to remove.
#:
#: So `changed` and `full` land in NOT_NORMALISED and say so. Giving them a real
#: divisor means having check_guards report the cost it actually incurred, for
#: instance how many entries rebuilt, which is its own change.
WORK_PATTERNS: dict[str, tuple[str, str]] = {
    "swift-unit": (r"Swift: (\d+) tests", "tests executed"),
    "python": (r"(\d+) passed", "tests passed"),
    "macos": (r"(\d+) passed", "tests passed"),
    "reference-frames": (r"(\d+) passed", "tests passed"),
    # The guard jobs, since #1090 gave them a real divisor. They were the two
    # families left NOT_NORMALISED, because their logs report `N guards
    # checked` and dividing by a count of items whose costs differ by 90x hands
    # a bare comparison the confidence of a measured one, which is the defect
    # #1041 exists to remove. What they print now is the RECORDED cost of the
    # entries they proved, so a diff selecting more expensive entries raises
    # both halves and leaves the rate where it was, while a slower runner
    # raises only the duration.
    "changed": (r"guard work: (\d+) recorded entry-ms", "recorded entry-ms"),
    "full": (r"guard work: (\d+) recorded entry-ms", "recorded entry-ms"),
}


#: How each job family names a test that FAILED, in its own log (#1060).
#:
#: The logs are already read for the work counts, so the failures in them cost
#: nothing extra. A job family absent from here reports no failures rather than
#: guessing at a format, and the caller only counts a run it could actually read.
#: The pytest families' pattern, in one place rather than five copies (L41).
#:
#: NOT anchored to the start of a line, which is how it was written and why it
#: had never matched anything (#1085). GitHub's raw job log prefixes every line
#: with an ISO 8601 timestamp, so `^FAILED` met `2026-08-30T21:57:23.6243408Z
#: FAILED tests/...` and reported an empty set on every run there has ever been.
#: An empty set is what the flake counter treats as a clean run, so the counter
#: had never counted a failure and nothing said so.
#:
#: `\S+::\S+` rather than `\S+`, because a pytest node id always carries `::`
#: and that is what tells this from any other line containing the word FAILED,
#: such as xcodebuild's `** TEST FAILED **` (L104). Verified against two real
#: recorded logs by tests/test_ci_log_patterns_read_a_real_log.py.
A_PYTEST_FAILURE = r"FAILED (\S+::\S+)"

FAILURE_PATTERNS: dict[str, str] = {
    # The parallel runner's form, `Test case 'Class.method()' failed on
    # '<worker>'`. The serial runner printed `Test Case '-[Module.Class method]'
    # failed` and is not matched, deliberately: the suite has run in parallel
    # since #992 and a pattern covering a form nothing produces is a pattern
    # nothing can check.
    "swift-unit": r"Test case '([A-Za-z_]+\.[A-Za-z_]+\(\))' failed",
    "python": A_PYTEST_FAILURE,
    "macos": A_PYTEST_FAILURE,
    "reference-frames": A_PYTEST_FAILURE,
    "changed": A_PYTEST_FAILURE,
    "full": A_PYTEST_FAILURE,
}

#: The fewest runs a flake can be told from a single red run in.
#:
#: Two, because one run holding one failure is exactly what CI already shows,
#: and calling it intermittent would be a claim nothing measured (L98).
MINIMUM_FLAKE_WINDOW = 2


def failed_tests(log: str, job: str) -> set[str]:
    """Which tests failed in one run of `job`, read out of its own log."""
    pattern = FAILURE_PATTERNS.get(work_family(job))
    if not pattern:
        return set()
    return set(re.findall(pattern, log, re.M))


def flakes(failures: dict[str, list[set[str]]]) -> list[tuple[str, str, int, int]]:
    """Tests that failed in SOME runs of a window and not others, worst first.

    `failures` holds one set per run, newest first, aligned with the durations.

    A test that failed in EVERY run is not returned. It is broken rather than
    intermittent, it is already somebody's current problem, and ranking it here
    would bury the intermittent ones this exists to surface. That is the whole
    distinction: CI runs each commit once, so one red run reads as a real
    failure and a re-push reads as a fix, and nothing counted how often a given
    test did that (L293).

    Failures only, never passes. Reading which tests PASSED would mean parsing
    2,600 lines a run across the window for an answer this does not need: a
    count of failures against the number of runs READ says the same thing at no
    cost.
    """
    ranked: list[tuple[str, str, int, int]] = []
    for job, runs in sorted(failures.items()):
        if len(runs) < MINIMUM_FLAKE_WINDOW:
            continue
        counted: dict[str, int] = {}
        for run in runs:
            for name in run:
                counted[name] = counted.get(name, 0) + 1
        for name, times in counted.items():
            if times < len(runs):
                ranked.append((job, name, times, len(runs)))
    return sorted(ranked, key=lambda row: (-row[2], row[0], row[1]))


def work_family(job: str) -> str:
    """A job name with its matrix suffix removed."""
    return job.split(" (")[0].strip()


def work_done(log: str, job: str) -> int | None:
    """How much work one run of `job` did, read out of its own log.

    `None`, never 0, when it cannot be found. Zero is a real measurement of a
    job that did nothing, and the two must not collapse into one another (L11).

    The LAST match wins. A log holds every line the job printed, including a
    pytest header and any earlier partial run, and the final summary is the one
    that describes the whole job.
    """
    found = WORK_PATTERNS.get(work_family(job))
    if not found:
        return None
    matches = re.findall(found[0], log)
    return int(matches[-1]) if matches else None


def _rates(seconds: list[float],
           work: list[int | None] | None) -> list[float] | None:
    """Seconds per unit of work, or None when the whole window cannot be.

    All or nothing on purpose. Dropping the runs whose count is missing would
    move which runs fall in each half, so the comparison would be between two
    different populations chosen by which logs happened to parse (L288).
    """
    if work is None or len(work) != len(seconds):
        return None
    if any(count is None or count <= 0 for count in work):
        return None
    return [second / count for second, count in zip(seconds, work)]


def drift_of(job: str, seconds: list[float],
             work: list[int | None] | None = None) -> Verdict:
    """Compare the recent half of a job's durations against the older half.

    `seconds` arrives newest first, the order the Actions API returns runs in,
    and `work` is aligned with it.

    Divided by the work done wherever that can be had, so the series is a RATE
    rather than a total (#1041). A job whose cost depends on the CONTENT of the
    change it runs against, like the per-pull-request guard proof, otherwise
    reports the week's pull request sizes as a change in the job.
    """
    if len(seconds) < MINIMUM_WINDOW:
        return Verdict(
            Drift.NOT_ENOUGH_HISTORY,
            f"{job}: {len(seconds)} runs recorded, fewer than the "
            f"{MINIMUM_WINDOW} needed to compare two halves, so nothing is "
            f"claimed about it either way")

    half = len(seconds) // 2
    rates = _rates(seconds, work)
    unit = WORK_PATTERNS.get(work_family(job), (None, ""))[1]

    if rates is not None:
        recent, older = statistics.median(rates[:half]), statistics.median(rates[half:])
        counts = f"{statistics.median(work[half:]):.0f} to {statistics.median(work[:half]):.0f} {unit}"
        scale, per = 1000, f"ms per {unit.rstrip('s').split()[-1]}"
    else:
        recent, older = statistics.median(seconds[:half]), statistics.median(seconds[half:])
        counts, scale, per = "", 1, "s"

    if older <= 0:
        return Verdict(
            Drift.UNREADABLE,
            f"{job}: the older half medians {older:.0f}{per}, which cannot be "
            f"compared against. That is a job reporting no duration, not a "
            f"job that is fast")

    shift = (recent - older) / older
    moved = (f"{older * scale:.0f} to {recent * scale:.0f}{per} ({shift:+.0%})"
             + (f", on {counts}" if counts else ""))

    measured = noise_floor(job)

    if measured is not None:
        floor, where = measured
        if abs(shift) < floor:
            return Verdict(
                Drift.INSIDE_THE_NOISE,
                f"{job}: {moved}, which is inside the {floor:.0%} this runner "
                f"produces on IDENTICAL code ({where}), so nothing can be said "
                f"about it either way. To claim a real change here, take "
                f"several runs per arm and compare the medians, or use a "
                f"measure that is not wall clock (#1329)")

    if measured is not None:
        bar, why = measured
    else:
        broken = unreadable_floor(job)
        bar = MATERIAL_SHIFT
        why = (f"{broken} records a spread for this job but it could not be "
               f"read, so the shared default is standing in and the bar below "
               f"is NOT this runner's measured noise"
               if broken else
               "no measured spread for this job, so the shared default")

    if abs(shift) < bar:
        return Verdict(
            Drift.STEADY,
            f"{job}: {moved}, inside the {bar:.0%} that ordinary run to run "
            f"variation covers ({why})")

    if rates is None:
        return Verdict(
            Drift.NOT_NORMALISED,
            f"{job}: {moved}, and this job's workload could not be measured, "
            "so a job that got slower and a job that was given more to do are "
            "the same reading here. Nothing is claimed either way (#1041)")

    if shift > 0:
        return Verdict(
            Drift.SLOWER,
            f"{job}: SLOWER, {moved}, past the {bar:.0%} bar ({why}). The "
            "work is divided out, so this is the job costing more per unit "
            "rather than the week bringing bigger changes")

    return Verdict(
        Drift.FASTER,
        f"{job}: faster, {moved}, past the {bar:.0%} bar ({why})")


def did_its_work(job: dict, work_step: str | Iterable[str] | None) -> bool:
    """Whether a job that HAS one of the named work steps actually ran it.

    True for every job carrying none of them, which is what lets the whole set
    of names be passed for every workflow instead of a per-workflow table
    somebody has to remember to extend (L96). Two workflows need it: the guard
    sweep's shards skip their proof step (#989) and #990's gate skips the work
    of `python`, `macos`, `swift-unit` and `reference-frames` on a merge whose
    tree a green pull request already carried.

    A bare string is one name, not four characters. A string is iterable, so
    accepting several names without saying so would silently compare each step
    against `R`, `e`, `-` and match nothing, restoring the population this rule
    exists to drop while every existing caller still read as correct.

    Ran, not passed. A shard whose proof went red spent the time, and dropping
    it would hide a job getting slower right up until the moment it goes red,
    which is the direction that matters most here.
    """
    if not work_step:
        return True
    wanted = ({work_step} if isinstance(work_step, str)
              else {str(name) for name in work_step if name})
    if not wanted:
        return True
    for step in job.get("steps") or []:
        if str(step.get("name") or "").strip() not in wanted:
            continue
        return str(step.get("conclusion") or "").lower() not in (
            "skipped", "cancelled", "")
    return True


def measurable_jobs(runs: list[dict], *,
                    work_step: str | Iterable[str] | None = None):
    """Every (name, seconds, job) this series is allowed to measure.

    ONE walk, because `job_durations` and `work_series` have to agree exactly:
    two walks filtering separately would pair a duration with another run's
    count and every rate would be wrong in a way nothing could see (L228). It is
    also the only place these rules live, so there is no second copy to drift
    (L41).

    A job that has not finished contributes NOTHING rather than a zero. A zero
    would pull the median down and read as the job having become fast, which is
    the opposite of what an unfinished run means (L215).

    A SKIPPED job contributes nothing either, and it is excluded by its SHAPE
    rather than by its label. Measured on 2026-08-30 against this repository's
    API, GitHub stamps a skipped job's `completed_at` one second BEFORE its
    `started_at`: the `full` job, skipped on every pull request, reported
    13:19:13Z to 13:19:12Z. A non-positive duration is never a reading of
    anything, whatever produced it (L50), so that one test covers the skipped
    case and every other inverted pair at once.

    A job that RAN and had nothing to do contributes nothing either, which is
    a different case and needs its own rule (#989, #990). Since the guard sweep
    moved to a daily cadence its shards skip their own expensive STEPS rather
    than the job, and since #990 the post-merge jobs do the same, so such a job
    still checks out, asks its gate and exits successful in well under a minute.
    That is a positive duration, so the shape check waves it through, and the
    series would then hold two populations decided by the week's merge pattern
    rather than by anything about the job (L36, and L102: a cost measured while
    the expensive path is switched off measures the short circuit rather than
    the work).

    A second check on `conclusion == "skipped"` was written first and removed:
    `check_guards` reported it SURVIVED its mutation, because breaking it
    changed no test, because every skipped job the API actually produces is
    already caught by the shape. A branch nothing can be shown to need is a
    branch nobody can maintain, and keeping it "to be safe" would have meant
    shipping an unproven one (L29).
    """
    for run in runs:
        for job in run.get("jobs", []):
            started, completed = job.get("started_at"), job.get("completed_at")
            if not started or not completed:
                continue
            if not did_its_work(job, work_step):
                continue
            try:
                begin = datetime.fromisoformat(started.replace("Z", "+00:00"))
                end = datetime.fromisoformat(completed.replace("Z", "+00:00"))
            except (ValueError, AttributeError):
                continue
            lasted = (end - begin).total_seconds()
            if lasted <= 0:
                continue
            yield str(job.get("name", "?")), lasted, job


def job_durations(runs: list[dict], *,
                  work_step: str | Iterable[str] | None = None,
                  ) -> dict[str, list[float]]:
    """Seconds each named job took, newest run first."""
    series: dict[str, list[float]] = {}
    for name, lasted, _job in measurable_jobs(runs, work_step=work_step):
        series.setdefault(name, []).append(lasted)
    return series


def recent_runs(workflow: str, window: int) -> list[dict]:
    """The last `window` completed runs of one workflow, with their jobs.

    One call for the runs and one per run for its jobs. That is why this belongs
    on a schedule rather than on every push.
    """
    path = (f"repos/{{owner}}/{{repo}}/actions/workflows/{workflow}/runs"
            f"?status=completed&per_page={window}")
    reply = gh_json(path)
    runs = reply.get("workflow_runs")
    if not isinstance(runs, list):
        raise GhUnusable(f"gh api {path} returned no workflow_runs list")

    carried = []
    for run in runs:
        jobs_path = f"repos/{{owner}}/{{repo}}/actions/runs/{run['id']}/jobs"
        jobs = gh_json(jobs_path).get("jobs")
        if not isinstance(jobs, list):
            raise GhUnusable(f"gh api {jobs_path} returned no jobs list")
        carried.append({**run, "jobs": jobs})
    return carried


def job_log(job_id: int, read=None) -> str:
    """One job's raw log, or "" when it cannot be had.

    Empty, not an exception. A log that will not download is a run whose work
    count is unknown, and unknown is already a first class answer here: it lands
    the job in NOT_NORMALISED rather than taking the whole check down (L73).
    """
    reader = read or (lambda path: subprocess.run(
        ["gh", "api", path], capture_output=True, text=True,
        check=False).stdout)
    try:
        return reader(f"repos/{{owner}}/{{repo}}/actions/jobs/{job_id}/logs")
    except Exception:  # noqa: BLE001  a log is never worth failing the check for
        return ""


def read_logs(runs: list[dict], *, work_step: str | Iterable[str] | None = None,
              read_log=None,
              ) -> tuple[dict[str, list[int | None]], dict[str, list[set[str]]]]:
    """Each job's work count and its failed tests, run by run.

    One pass and one log download per job, because both answers come out of the
    same text and fetching it twice would double the only expensive part of this
    (#1039, #1060).

    Aligned by construction: it walks `measurable_jobs`, the same generator
    `job_durations` walks, so the three cannot select different jobs however any
    of them changes (L228).

    A job whose log could not be read contributes NO run to the flake window
    rather than an empty set of failures. An empty set is the same shape as a
    run that passed everything, so counting one would quietly grow the
    denominator and make a real flake look rarer than it is (L98).
    """
    counts: dict[str, list[int | None]] = {}
    failures: dict[str, list[set[str]]] = {}
    for name, _lasted, job in measurable_jobs(runs, work_step=work_step):
        identifier = job.get("id")
        family = work_family(name)
        wanted = family in WORK_PATTERNS or family in FAILURE_PATTERNS
        log = (job_log(identifier, read=read_log)
               if isinstance(identifier, int) and wanted else "")
        counts.setdefault(name, []).append(
            work_done(log, name) if log else None)
        if log:
            failures.setdefault(name, []).append(failed_tests(log, name))
    return counts, failures


def work_series(runs: list[dict], *, work_step: str | Iterable[str] | None = None,
                read_log=None) -> dict[str, list[int | None]]:
    """How much work each named job did, run by run, aligned with `job_durations`."""
    return read_logs(runs, work_step=work_step, read_log=read_log)[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--workflow", default="swift.yml",
                        help="the workflow file to read the series from")
    parser.add_argument("--window", type=int, default=16,
                        help="how many completed runs to read")
    parser.add_argument("--work-step", action="append", default=None,
                        help="a job carrying a step by this name is measured "
                             "only when that step actually ran; jobs without "
                             "one are unaffected. Repeatable. Defaults to "
                             "every step name a gate in this repository can "
                             "skip, which is safe to pass for every workflow "
                             "because a job carrying none of them is left "
                             "alone (L96)")
    parser.add_argument("--no-work-counts", action="store_true",
                        help="skip reading each job's log for how much work it "
                             "did, so every verdict is of totals and says so")
    args = parser.parse_args(argv)

    try:
        runs = recent_runs(args.workflow, args.window)
    except GhUnusable as unusable:
        # Could not ask is not the same as asked and found nothing healthy, and
        # must not be allowed to look like it (L98).
        print(f"::warning::Could not read the run history for "
              f"{args.workflow}, so no job's duration was judged: {unusable}")
        return 0

    steps = args.work_step or WORK_STEPS
    durations = job_durations(runs, work_step=steps)
    work, failures = (({}, {}) if args.no_work_counts
                      else read_logs(runs, work_step=steps))
    verdicts = [drift_of(job, seconds, work=work.get(job))
                for job, seconds in sorted(durations.items())]
    repeat_offenders = flakes(failures)

    lines = []
    for verdict in verdicts:
        print(verdict.message)
        if verdict.state.is_alarming:
            print(f"::warning::{verdict.message}")
        lines.append(f"- {verdict.message}")

    if not verdicts:
        # An empty series after a successful read is its own outcome: it means
        # the window held no finished job at all, which reads exactly like a
        # healthy quiet week unless it is said out loud (L98).
        print(f"::warning::{args.workflow} reported no finished jobs in its "
              f"last {args.window} runs, so nothing was measured")

    # Beside the durations rather than anywhere else, because a flake is a
    # speed cost priced at a full re-run and belongs with the speed findings
    # rather than in a reliability backlog nobody reads (L293).
    for job, name, times, of in repeat_offenders:
        note = (f"{job}: {name} failed {times} of {of} runs. A test that fails "
                "only sometimes reads as a real failure once and as fixed on "
                "the re-push, so its cost is paid again every time")
        print(f"::warning::{note}")
        lines.append(f"- {note}")
    if not repeat_offenders and failures:
        print(f"no test failed in some runs of {args.workflow} and not others")

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### CI job durations: {args.workflow}\n\n"
                         + ("\n".join(lines) or "nothing measured") + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
