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
import os
import statistics
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.wait_for_checks import GhUnusable, gh_json  # noqa: E402

#: How far the two halves' medians must differ before it is worth saying.
#:
#: Derived from the two shifts the issue measured rather than chosen for feeling
#: about right. The Swift leg moved 11.3% in a week and is the case this exists
#: to catch; the Python leg moved 3.8% over the same window and is presented
#: there as ordinary. 8% sits between them with room on both sides, so the
#: reading that prompted the issue fires and the one it treats as normal does
#: not (L172).
MATERIAL_SHIFT = 0.08

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
        """Whether this deserves a warning annotation rather than a log line."""
        return self in (Drift.SLOWER, Drift.UNREADABLE)


@dataclass(frozen=True)
class Verdict:
    state: Drift
    message: str


def drift_of(job: str, seconds: list[float]) -> Verdict:
    """Compare the recent half of a job's durations against the older half.

    `seconds` arrives newest first, the order the Actions API returns runs in.
    """
    if len(seconds) < MINIMUM_WINDOW:
        return Verdict(
            Drift.NOT_ENOUGH_HISTORY,
            f"{job}: {len(seconds)} runs recorded, fewer than the "
            f"{MINIMUM_WINDOW} needed to compare two halves, so nothing is "
            f"claimed about it either way")

    half = len(seconds) // 2
    recent = statistics.median(seconds[:half])
    older = statistics.median(seconds[half:])

    if older <= 0:
        return Verdict(
            Drift.UNREADABLE,
            f"{job}: the older half medians {older:.0f}s, which cannot be "
            f"compared against. That is a job reporting no duration, not a "
            f"job that is fast")

    shift = (recent - older) / older
    moved = f"{older:.0f}s to {recent:.0f}s ({shift:+.0%})"

    if abs(shift) < MATERIAL_SHIFT:
        return Verdict(
            Drift.STEADY,
            f"{job}: {moved}, inside the {MATERIAL_SHIFT:.0%} that ordinary "
            f"run to run variation covers")

    if shift > 0:
        return Verdict(
            Drift.SLOWER,
            f"{job}: SLOWER, {moved}. Check the executed test count beside "
            f"this: a count rising with the seconds is a suite doing more "
            f"work, the same count taking longer is a regression")

    return Verdict(
        Drift.FASTER,
        f"{job}: faster, {moved}")


def job_durations(runs: list[dict]) -> dict[str, list[float]]:
    """Seconds each named job took, newest run first.

    A job that has not finished contributes NOTHING rather than a zero. A zero
    would pull the median down and read as the job having become fast, which is
    the opposite of what an unfinished run means (L215).
    """
    series: dict[str, list[float]] = {}
    for run in runs:
        for job in run.get("jobs", []):
            started, completed = job.get("started_at"), job.get("completed_at")
            if not started or not completed:
                continue
            try:
                begin = datetime.fromisoformat(started.replace("Z", "+00:00"))
                end = datetime.fromisoformat(completed.replace("Z", "+00:00"))
            except (ValueError, AttributeError):
                continue
            series.setdefault(str(job.get("name", "?")), []).append(
                (end - begin).total_seconds())
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--workflow", default="swift.yml",
                        help="the workflow file to read the series from")
    parser.add_argument("--window", type=int, default=16,
                        help="how many completed runs to read")
    args = parser.parse_args(argv)

    try:
        runs = recent_runs(args.workflow, args.window)
    except GhUnusable as unusable:
        # Could not ask is not the same as asked and found nothing healthy, and
        # must not be allowed to look like it (L98).
        print(f"::warning::Could not read the run history for "
              f"{args.workflow}, so no job's duration was judged: {unusable}")
        return 0

    verdicts = [drift_of(job, seconds)
                for job, seconds in sorted(job_durations(runs).items())]

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

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### CI job durations: {args.workflow}\n\n"
                         + ("\n".join(lines) or "nothing measured") + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
