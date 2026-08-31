#!/usr/bin/env python3
"""Keep one real CI job log, so the patterns that read logs can be held to it (#1085).

`tools/check_job_durations.py` reads each job's log by regex twice over:
`WORK_PATTERNS` for how much work the job did, which is what makes the duration
series a rate rather than a total (#1039), and `FAILURE_PATTERNS` for which
tests failed (#1060, the flake counter). A pattern that stops matching returns
None or an empty set, which both tools are built to treat as "could not
measure" rather than as an error. The failure is quiet by design at the call
site and had nothing watching it upstream.

The format has already moved twice, and the second had been broken since the
day it shipped:

* a check for passing Swift tests written as `Test Case '...' passed` found ZERO
  on a run that passed 2,610, because parallel running prints
  `Test case '...' passed on '<worker>'`. Noticed by hand while reading a suite
  result;
* every pytest failure pattern was anchored as `^FAILED`, and matched ZERO on
  every log there has ever been, because GitHub's raw job log prefixes each line
  with an ISO 8601 timestamp. The flake counter had never counted a failure.
  Found by running the pattern over a recorded log while writing this.

So the patterns are calibrated against a REAL recorded log rather than against a
reimplementation of the format, the way `tools/wait_for_checks.py` is calibrated
against GitHub's own reply (L52). Recording one is cheap: measured on
2026-08-31, 1.15MB and 0.7s for `swift-unit`, about 160KB gzipped.

    tools/record_ci_log.py --job <job id> --as <name>

The log is stored VERBATIM and gzipped, timestamps included, because the
timestamps are exactly what the second defect was about: a fixture with them
stripped would be a fixture shaped so the rule fires (L48).

What each log HOLDS is not written by this tool. The expected counts and failure
names are filled into the manifest by hand, read off the log, because a fixture
whose expectations were produced by the code under test can only ever prove that
code agrees with itself (L58, L70).
"""

from __future__ import annotations

import argparse
import gzip
import json
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOGS = REPO_ROOT / "tests" / "fixtures" / "ci_logs"
MANIFEST = LOGS / "manifest.json"


def fetch(job_id: int) -> str:
    """One job's raw log, or a refusal.

    A refusal rather than an empty string, unlike `check_job_durations.job_log`.
    That one is right to shrug: a log it cannot read lands the job in
    NOT_NORMALISED and the check goes on. This one exists to WRITE a fixture,
    and an empty fixture is one every pattern passes against (L98).
    """
    found = subprocess.run(
        ["gh", "api", f"repos/{{owner}}/{{repo}}/actions/jobs/{job_id}/logs"],
        capture_output=True, text=True, check=False)
    if found.returncode != 0 or not found.stdout.strip():
        raise SystemExit(
            f"job {job_id}'s log could not be read: "
            f"{found.stderr.strip() or 'it came back empty'}. Nothing was written.")
    return found.stdout


def job_facts(job_id: int) -> dict:
    """What GitHub says about the job, so the fixture carries its own provenance."""
    found = subprocess.run(
        ["gh", "api", f"repos/{{owner}}/{{repo}}/actions/jobs/{job_id}"],
        capture_output=True, text=True, check=False)
    if found.returncode != 0:
        raise SystemExit(f"job {job_id} could not be described: {found.stderr.strip()}")
    reply = json.loads(found.stdout)
    return {
        "job": job_id,
        "job_name": reply.get("name"),
        "run": reply.get("run_id"),
        "conclusion": reply.get("conclusion"),
        "started_at": reply.get("started_at"),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--job", type=int, required=True, help="a job id")
    parser.add_argument("--as", dest="name", required=True,
                        help="what to call the fixture, e.g. python-red")
    args = parser.parse_args(argv)

    log = fetch(args.job)
    LOGS.mkdir(parents=True, exist_ok=True)
    path = LOGS / f"{args.name}.log.gz"
    # mtime=0 so re-recording the same log produces the same bytes and a diff
    # shows a changed LOG rather than a changed timestamp.
    path.write_bytes(gzip.compress(log.encode("utf-8"), mtime=0))

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8")) \
        if MANIFEST.exists() else {"logs": {}}
    entry = manifest["logs"].get(args.name, {})
    entry.update(job_facts(args.job))
    entry.update({
        "recorded_on": time.strftime("%Y-%m-%d"),
        "bytes": len(log),
        "lines": log.count("\n"),
    })
    # Never written by this tool: what the log HOLDS is read off it by a person
    # and is the independent half of the comparison (L58).
    entry.setdefault("holds", {
        "work": None,
        "failed_tests": None,
        "read_off": "FILL IN: quote the line each number was read from",
    })
    manifest["logs"][args.name] = entry
    manifest["logs"] = dict(sorted(manifest["logs"].items()))
    MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8")

    print(f"recorded {args.name}: {len(log)} bytes, {path.stat().st_size} gzipped, "
          f"from job {args.job} of run {entry['run']} ({entry['conclusion']})")
    if entry["holds"].get("work") is None:
        print("  now fill in its `holds` in tests/fixtures/ci_logs/manifest.json, "
              "read off the log by hand")
    return 0


if __name__ == "__main__":
    sys.exit(main())
