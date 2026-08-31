#!/usr/bin/env python3
"""How long the per-pull-request guard job actually takes (#1086).

The `changed` job's deadline is chosen from the distribution of its own past
runs, and `tests/fixtures/changed_job_timing.json` holds those readings so the
choice can be re-measured rather than believed (L316). This re-measures it.

    venv/bin/python tools/measure_changed_job.py [--write]

Without `--write` it prints the reading and changes nothing, which is what you
want when checking whether the record has drifted. With it, the record is
rewritten and the `why_900` and `what_expired` prose is left alone: the numbers
are a measurement and the prose is a judgement about them, and overwriting the
judgement from a script would silently replace the reason with nothing.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORD = REPO_ROOT / "tests" / "fixtures" / "changed_job_timing.json"
JOB = "changed"


def api(path: str) -> dict:
    found = subprocess.run(["gh", "api", path], capture_output=True, text=True,
                           check=False)
    if found.returncode != 0:
        raise SystemExit(f"gh api {path} failed: {found.stderr.strip()}")
    return json.loads(found.stdout)


def durations() -> list[int]:
    """Every finished `changed` run's wall clock, oldest first.

    Only runs that reached a verdict. A cancelled or skipped one has a duration
    that measures when somebody pushed again, not what the job costs (L331).
    """
    runs = api("repos/{owner}/{repo}/actions/workflows/guards.yml/runs?per_page=100")
    seconds: list[int] = []
    for run in runs["workflow_runs"]:
        for job in api(f"repos/{{owner}}/{{repo}}/actions/runs/{run['id']}/jobs")["jobs"]:
            if job["name"] != JOB or job["conclusion"] not in ("success", "failure"):
                continue
            if not (job.get("started_at") and job.get("completed_at")):
                continue
            began = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
            ended = datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
            seconds.append(round((ended - began).total_seconds()))
    if not seconds:
        raise SystemExit(
            "no finished `changed` job was found in the last 100 guard runs, so "
            "there is nothing to measure. An empty reading would rewrite the "
            "record as a job that costs nothing (L98). Nothing was written.")
    return sorted(seconds)


def percentile(seconds: list[int], share: float) -> int:
    return seconds[min(len(seconds) - 1, int(share * len(seconds)))]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--write", action="store_true",
                        help="rewrite the record, keeping its prose")
    args = parser.parse_args(argv)

    seconds = durations()
    print(f"runs={len(seconds)} min={seconds[0]} "
          f"median={statistics.median(seconds):.0f} "
          f"p75={percentile(seconds, 0.75)} p90={percentile(seconds, 0.90)} "
          f"max={seconds[-1]}")

    if not args.write:
        print("not written; pass --write to update "
              f"{RECORD.relative_to(REPO_ROOT)}")
        return 0

    record = json.loads(RECORD.read_text(encoding="utf-8"))
    record["seconds"] = seconds
    record["runs"] = len(seconds)
    record["measured_on"] = time.strftime("%Y-%m-%d")
    RECORD.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {RECORD.relative_to(REPO_ROOT)}; its prose is unchanged and "
          "may no longer describe these numbers, so read it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
