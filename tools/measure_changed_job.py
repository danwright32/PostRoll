#!/usr/bin/env python3
"""How long the per-pull-request guard job actually takes (#1086).

The `changed` job's deadline is chosen from the distribution of its own past
runs, and `tests/fixtures/changed_job_timing.json` holds those readings so the
choice can be re-measured rather than believed (L316). This re-measures it.

    venv/bin/python tools/measure_changed_job.py [--write]

Without `--write` it prints the reading and changes nothing, which is what you
want when checking whether the record has drifted. With it, the record is
rewritten and the `why_850` and `what_expired` prose is left alone: the numbers
are a measurement and the prose is a judgement about them, and overwriting the
judgement from a script would silently replace the reason with nothing.

## What each reading is made of, not just how long it took (#1351)

A duration on its own cannot say whether the run did any work. The job proves
the registry entries a diff affected and prints how many, so each reading now
carries that count, read out of the job's own log. Measured on 2026-09-05 over
94 readings: 15 of them proved NOTHING and returned in setup time, with a
median of 43s against 75s for the rest, so a sample nobody can describe was
dragging every percentile down and reading as a fast job (L331).

A log that cannot be read records `null`, never 0. Those are different things:
0 is a run that proved nothing, null is a run nobody can say anything about,
and collapsing them would count GitHub's 90 day log retention as evidence that
old runs did no work (L11).

## What --write reports afterwards

The rules the deadline has to satisfy live in
`tests/test_the_pr_guard_job_has_a_deadline.py`, so `--write` RUNS them rather
than restating any of them here: a second copy of a rule beside the first is a
second thing to keep in step, and it drifts in the direction that flatters the
number (L107). The re-measure then names the work it created instead of
printing a warning to go and look.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORD = REPO_ROOT / "tests" / "fixtures" / "changed_job_timing.json"
DEADLINE_RULES = REPO_ROOT / "tests" / "test_the_pr_guard_job_has_a_deadline.py"
JOB = "changed"

#: A run proving this many entries or more is a WIDE one: the case the deadline
#: exists for. Held to the same number the rules are written against.
WIDE_AT = 5

#: What the job prints about how much of the registry the diff reached.
AFFECTED = re.compile(r"--changed: (\d+) of (\d+) entries affected")


@dataclass(frozen=True)
class Reading:
    """One finished run: how long it took, and how much it proved.

    `entries` is None when the log could not be read, which is not the same as
    a run that proved none of them (L11).
    """

    seconds: int
    entries: int | None

    def as_record(self) -> dict:
        return {"seconds": self.seconds, "entries": self.entries}


def api(path: str) -> dict:
    found = subprocess.run(["gh", "api", path], capture_output=True, text=True,
                           check=False)
    if found.returncode != 0:
        raise SystemExit(f"gh api {path} failed: {found.stderr.strip()}")
    return json.loads(found.stdout)


def job_log(job_id: int) -> str | None:
    """One job's log, or None when GitHub will not hand it over.

    None rather than "" so a log aged out of GitHub's retention cannot be read
    as a run that printed nothing.
    """
    found = subprocess.run(
        ["gh", "api", f"repos/{{owner}}/{{repo}}/actions/jobs/{job_id}/logs"],
        capture_output=True, text=True, check=False)
    return found.stdout if found.returncode == 0 and found.stdout else None


def entries_proved(log: str | None) -> int | None:
    """How many registry entries that run proved, from its own log."""
    if log is None:
        return None
    found = AFFECTED.search(log)
    if found:
        return int(found.group(1))
    # The job says this in so many words when the diff reached nothing, and it
    # is a real zero rather than an unreadable log.
    if "no registered guard is affected by this diff" in log:
        return 0
    return None


def readings(*, ask: Callable[[str], dict] | None = None,
             log: Callable[[int], str | None] | None = None) -> list[Reading]:
    """Every finished `changed` run, shortest first, with what it proved.

    Only runs that reached a verdict. A cancelled or skipped one has a duration
    that measures when somebody pushed again, not what the job costs (L331).
    """
    ask = ask or api
    log = log or job_log
    found: list[Reading] = []
    runs = ask("repos/{owner}/{repo}/actions/workflows/guards.yml/runs?per_page=100")
    for run in runs["workflow_runs"]:
        for job in ask(f"repos/{{owner}}/{{repo}}/actions/runs/{run['id']}/jobs")["jobs"]:
            if job["name"] != JOB or job["conclusion"] not in ("success", "failure"):
                continue
            if not (job.get("started_at") and job.get("completed_at")):
                continue
            began = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
            ended = datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
            found.append(Reading(seconds=round((ended - began).total_seconds()),
                                 entries=entries_proved(log(int(job["id"])))))
    if not found:
        raise SystemExit(
            "no finished `changed` job was found in the last 100 guard runs, so "
            "there is nothing to measure. An empty reading would rewrite the "
            "record as a job that costs nothing (L98). Nothing was written.")
    return sorted(found, key=lambda reading: reading.seconds)


def composition(found: list[Reading], wide_at: int = WIDE_AT) -> dict:
    """What the sample is MADE of, so a skewed one cannot read as a fair one.

    Four counts rather than a share, because each answers a different question
    and a single percentage would hide which of them moved.
    """
    return {
        "wide_at": wide_at,
        "proved_nothing": sum(1 for r in found if r.entries == 0),
        "narrow": sum(1 for r in found
                      if r.entries is not None and 0 < r.entries < wide_at),
        "wide": sum(1 for r in found
                    if r.entries is not None and r.entries >= wide_at),
        "unreadable": sum(1 for r in found if r.entries is None),
    }


def deadline_rules_failing(*, run: Callable[..., object] | None = None) -> list[str]:
    """Which of the deadline's own rules the record no longer satisfies.

    Run rather than restated: they are the definition, and a copy here would be
    a second one to keep in step, drifting in the direction that flatters the
    number (L107).

    A run that failed while naming no test is its own answer. Reporting that as
    an empty list would read as the rules passing, which is the one thing it
    does not mean (L98).
    """
    run = run or subprocess.run
    done = run(
        [sys.executable, "-m", "pytest", str(DEADLINE_RULES), "-q", "--no-header",
         "-p", "no:cacheprovider"],
        capture_output=True, text=True, check=False, cwd=str(REPO_ROOT))
    if done.returncode == 0:
        return []
    failing = re.findall(r"^FAILED [^:]+::(\w+)", done.stdout or "", re.M)
    return failing or [f"pytest exited {done.returncode} and named no test, so "
                       "nothing here can say which rule moved; run it yourself: "
                       f"pytest {DEADLINE_RULES.name}"]


def percentile(seconds: list[int], share: float) -> int:
    return seconds[min(len(seconds) - 1, int(share * len(seconds)))]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--write", action="store_true",
                        help="rewrite the record, keeping its prose")
    args = parser.parse_args(argv)

    found = readings()
    seconds = [reading.seconds for reading in found]
    working = [reading.seconds for reading in found if reading.entries]
    made_of = composition(found)
    print(f"runs={len(seconds)} min={seconds[0]} "
          f"median={statistics.median(seconds):.0f} "
          f"p75={percentile(seconds, 0.75)} p90={percentile(seconds, 0.90)} "
          f"max={seconds[-1]}")
    print(f"of those, {made_of['wide']} proved {WIDE_AT} entries or more, "
          f"{made_of['narrow']} fewer, {made_of['proved_nothing']} proved "
          f"nothing at all, and {made_of['unreadable']} could not be read")
    if working:
        print(f"the runs that proved something: n={len(working)} "
              f"median={statistics.median(working):.0f} "
              f"p75={percentile(working, 0.75)} p90={percentile(working, 0.90)} "
              f"max={max(working)}")

    if not args.write:
        print("not written; pass --write to update "
              f"{RECORD.relative_to(REPO_ROOT)}")
        return 0

    record = json.loads(RECORD.read_text(encoding="utf-8"))
    record["seconds"] = seconds
    record["readings"] = [reading.as_record() for reading in found]
    record["composition"] = made_of
    record["runs"] = len(seconds)
    record["measured_on"] = time.strftime("%Y-%m-%d")
    RECORD.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {RECORD.relative_to(REPO_ROOT)}; its prose is unchanged and "
          "may no longer describe these numbers, so read it")

    failing = deadline_rules_failing()
    if failing:
        print("the deadline no longer satisfies these rules in "
              f"{DEADLINE_RULES.relative_to(REPO_ROOT)}:")
        for name in failing:
            print(f"  {name}")
        print("Pick a deadline these readings support, and say why in the "
              "record's prose.")
        return 1
    print("the deadline still satisfies every rule in "
          f"{DEADLINE_RULES.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
