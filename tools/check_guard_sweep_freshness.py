"""Notice when the weekly guard sweep stops running (#554).

#551 gave `.github/workflows/guards.yml` a `schedule` trigger, so the full sweep
re-proves every guard through a quiet period rather than only when something
merges. That closed one gap and opened another: a scheduled job's ABSENCE is
invisible. GitHub disables a repository's schedules after 60 days with no push
and reports nothing at all rather than reporting that it stopped, and a run that
fails is only as visible as GitHub's own email, which is the channel this
project has already learned not to rely on.

So the absence of an expected run is reported here as its own outcome (L13).

## Why it warns rather than fails

A stale schedule does not make the change being merged wrong. Failing a run for
it would stop unrelated work for an unrelated reason, which is how a check
teaches everyone to bypass it, and a check that is always bypassed is the same
as no check (L36). It emits a GitHub Actions warning annotation and a job
summary line instead, both of which are visible on the run page without
blocking. The one thing it will not do is stay quiet.

## Where it runs

In the guard workflow itself rather than in the Linux test leg the issue
suggested. It keeps a warning about the guard sweep on the guard sweep's own run
instead of putting it in front of every pull request.

Since #989 that run is the daily scheduled one rather than one per merge, and
this step sits OUTSIDE the gate that decides whether the sweep itself runs. That
placement is the point: a gate stuck shut produces runs that complete, conclude
success, and prove nothing, and this is the only thing that would say so. Behind
the gate it would go quiet in exactly the situation it exists to report (L106).
"""

from __future__ import annotations

import argparse
import enum
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.guard_sweep_history import (  # noqa: E402
    HistoryUnreadable, Sweep, recent_sweeps)

#: Twice the cadence the sweep is guaranteed at, so one missed or delayed run is
#: not an alarm and two in a row is. An alert with a window shorter than what it
#: measures fires on ordinary variation and gets ignored (L36).
#:
#: The cadence used to be the weekly cron this was written against. Since #989
#: the sweep runs daily on any day main moved, and `tools/check_guard_sweep_due`
#: forces one anyway once the newest proof passes its own seven day window, so
#: seven days is still the longest gap between proofs that is not a fault and
#: fourteen is still twice it. Both numbers move together or neither does.
DEFAULT_WINDOW = timedelta(days=14)

#: Named in every message, because a notice that does not say what to look at
#: leaves the reader knowing something is wrong and with nowhere to go (L80).
WORKFLOW = "Guard proofs"


class Freshness(enum.Enum):
    FRESH = "fresh"
    STALE = "stale"
    #: No scheduled run has EVER happened. Distinct from stale on purpose: this
    #: is a schedule that has not come round yet, not one that has stopped, and
    #: reporting it as either would be a claim the evidence does not support
    #: (L98).
    NOT_YET_RUN = "not yet run"
    #: Scheduled runs are happening and none of them proved anything. Since #989
    #: the sweep's steps are conditional, so a run that skipped still concludes
    #: success and still sits at the top of the history. Counting runs rather
    #: than proofs would report that as a healthy schedule for as long as it
    #: lasted, which is a liveness signal emitted over dead work (L106). It is
    #: also NOT the same as no run yet: that one is quiet on purpose, and giving
    #: the quiet answer to this situation is how it would stay unnoticed (L11).
    NEVER_PROVED = "never proved"
    #: A timestamp that could not be read. Never allowed to compare as healthy:
    #: a failed parse landing on the permissive side of a threshold is the one
    #: way this check could report green for a reason unrelated to the truth
    #: (L50).
    UNREADABLE = "unreadable"


@dataclass(frozen=True)
class Verdict:
    state: Freshness
    message: str

    @property
    def exit_code(self) -> int:
        """Always zero. This check reports; it does not gate.

        Stated as one rule for every state rather than per state, because the
        first version had an unreadable TIMESTAMP exiting non-zero while an
        unreadable QUERY exited zero, which are the same condition (this check
        could not do its job) wearing two different answers. Anyone reading it
        would have had to work out which failure mode fails the build.

        Nothing here makes the change being merged wrong, so nothing here stops
        it (L36). The visibility is the warning annotation and the job summary,
        which is what this exists to produce. If that proves too quiet to act
        on, escalating is a one line change here rather than a redesign.
        """
        return 0

    @property
    def is_alarming(self) -> bool:
        """Whether this state needs a warning annotation rather than a line of
        log nobody scrolls to."""
        return self.state in (Freshness.STALE, Freshness.UNREADABLE,
                              Freshness.NEVER_PROVED)


def _parsed(raw: str) -> datetime | None:
    try:
        when = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def proved_anything(sweep: Sweep) -> bool:
    """Whether a run's proof step actually executed on any shard.

    One predicate, read by the filter below and by the count of the runs it
    rejects, so the two halves of the same answer cannot drift into disagreeing
    about which runs were real (L261).

    Deliberately not "passed". A red shard is a shard that RAN, and this is the
    question of whether proving is still happening, not whether it is green.
    Counting only green would make one broken guard read as a dead schedule,
    which is an alarm about the wrong thing that its own named remedy cannot
    clear (L144).
    """
    return bool(sweep.ran_shards)


def runs_that_proved(sweeps: list[Sweep]) -> list[dict]:
    """The stamps of the runs that actually proved something, for `verdict`."""
    return [{"created_at": sweep.created_at.isoformat()}
            for sweep in sweeps
            if proved_anything(sweep) and sweep.created_at is not None]


def verdict(runs: list[dict], *, now: datetime,
            window: timedelta = DEFAULT_WINDOW,
            ran_but_proved_nothing: int = 0) -> Verdict:
    """What the recorded scheduled runs say about whether the sweep is alive.

    `now` is injected rather than read, so a test can pin both ends of the
    comparison. A fixture whose meaning is its relationship to the clock and
    which pins only one end silently changes case as real time passes (L130).
    """
    if not runs and ran_but_proved_nothing:
        return Verdict(
            Freshness.NEVER_PROVED,
            f"{ran_but_proved_nothing} scheduled '{WORKFLOW}' runs completed "
            "and not one of them proved a single guard: every one skipped its "
            "proof step. The daily sweep only skips when the tree it is looking "
            "at was already proved, so this is that gate stuck shut "
            "(tools/check_guard_sweep_due.py), not a quiet week. Nothing has "
            "re-proved the registry for as long as this has been true.")
    if not runs:
        return Verdict(
            Freshness.NOT_YET_RUN,
            f"No scheduled '{WORKFLOW}' run has completed yet. This is expected "
            "until the first one falls due; if it stays this way past a week, "
            "the schedule is not firing.")

    stamps = [_parsed(r.get("created_at", "")) for r in runs]
    readable = [s for s in stamps if s is not None]
    if not readable:
        return Verdict(
            Freshness.UNREADABLE,
            f"The completion times for '{WORKFLOW}' could not be read, so "
            "nothing here can say whether the sweep is still running. Treated "
            "as a failure of this check rather than as a healthy sweep.")

    newest = max(readable)
    age = now - newest
    days = int(age.total_seconds() // 86400)
    if age <= window:
        return Verdict(
            Freshness.FRESH,
            f"The scheduled '{WORKFLOW}' sweep last completed {days} days ago.")
    return Verdict(
        Freshness.STALE,
        f"The scheduled '{WORKFLOW}' sweep has not completed for {days} days, "
        f"which is past the {window.days} day window. Either it is failing, or "
        "GitHub has disabled this repository's schedules, which it does after "
        "60 days with no push and reports nowhere. Check the workflow's run "
        "history and re-enable it if it has been switched off.")


def scheduled_sweeps(repo: str | None = None) -> list[Sweep]:
    """Completed scheduled runs of the guard workflow, summarised by what each
    one actually proved.

    Through `tools/guard_sweep_history`, which is the same reading the daily
    gate makes, so the two cannot disagree about what a proof is. A failed query
    raises there, because an error read as an empty list would report
    NOT_YET_RUN forever (L98, L119).
    """
    return recent_sweeps(repo=repo, event="schedule", limit=20)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", default=None,
                        help="owner/name, when not running inside the repo")
    parser.add_argument("--window-days", type=int, default=DEFAULT_WINDOW.days)
    args = parser.parse_args(argv)

    try:
        sweeps = scheduled_sweeps(args.repo)
    except (HistoryUnreadable, subprocess.CalledProcessError,
            ValueError, KeyError) as exc:
        # The query failing is not the same as finding nothing, and must not be
        # allowed to look like it.
        print(f"::warning::Could not read the '{WORKFLOW}' run history, so "
              f"whether the scheduled sweep is still running is unknown: {exc}")
        return 0

    result = verdict(runs_that_proved(sweeps), now=datetime.now(timezone.utc),
                     window=timedelta(days=args.window_days),
                     ran_but_proved_nothing=sum(
                         1 for sweep in sweeps if not proved_anything(sweep)))

    print(result.message)
    if result.is_alarming:
        print(f"::warning::{result.message}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"### Scheduled guard sweep\n\n{result.message}\n")
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main())
