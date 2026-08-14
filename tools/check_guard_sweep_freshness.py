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
suggested. That job runs on every push to main and on the schedule, so the
notice is seen often, and it keeps a warning about the guard sweep on the guard
sweep's own run instead of putting it in front of every pull request.
"""

from __future__ import annotations

import argparse
import enum
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

#: Twice the weekly cadence, so one missed or delayed run is not an alarm and
#: two in a row is. An alert with a window shorter than what it measures fires
#: on ordinary variation and gets ignored (L36).
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
        # Only an unreadable answer is worth a non-zero exit, because it means
        # this check itself could not do its job, which must not pass silently.
        # Staleness warns; see the module docstring.
        return 1 if self.state is Freshness.UNREADABLE else 0


def _parsed(raw: str) -> datetime | None:
    try:
        when = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def verdict(runs: list[dict], *, now: datetime,
            window: timedelta = DEFAULT_WINDOW) -> Verdict:
    """What the recorded scheduled runs say about whether the sweep is alive.

    `now` is injected rather than read, so a test can pin both ends of the
    comparison. A fixture whose meaning is its relationship to the clock and
    which pins only one end silently changes case as real time passes (L130).
    """
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


def scheduled_runs(repo: str | None = None) -> list[dict]:
    """Successful scheduled runs of the guard workflow, newest first.

    Through the `gh` CLI so it uses the token the workflow already has, and
    returns [] only when the query genuinely found none. A failed query raises,
    because an error read as an empty list would report NOT_YET_RUN forever
    (L98, L119).
    """
    cmd = ["gh", "run", "list",
           "--workflow", "guards.yml",
           "--event", "schedule",
           "--status", "success",
           "--limit", "20",
           "--json", "createdAt"]
    if repo:
        cmd += ["--repo", repo]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return [{"created_at": r["createdAt"]} for r in json.loads(out)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", default=None,
                        help="owner/name, when not running inside the repo")
    parser.add_argument("--window-days", type=int, default=DEFAULT_WINDOW.days)
    args = parser.parse_args(argv)

    try:
        runs = scheduled_runs(args.repo)
    except (subprocess.CalledProcessError, ValueError, KeyError) as exc:
        # The query failing is not the same as finding nothing, and must not be
        # allowed to look like it.
        print(f"::warning::Could not read the '{WORKFLOW}' run history, so "
              f"whether the scheduled sweep is still running is unknown: {exc}")
        return 0

    result = verdict(runs, now=datetime.now(timezone.utc),
                     window=timedelta(days=args.window_days))

    print(result.message)
    if result.state in (Freshness.STALE, Freshness.UNREADABLE):
        print(f"::warning::{result.message}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"### Scheduled guard sweep\n\n{result.message}\n")
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main())
