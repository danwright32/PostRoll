#!/usr/bin/env python3
"""Record the replies the merge bar is calibrated against (#1343).

`tests/fixtures/gh_pr_checks_real.json`, `gh_actions_runs_real.json`,
`gh_actions_jobs_real.json` and `gh_workflow_listing_real.json` are real
replies about ONE pull request at ONE commit, and they have to be re-recorded
together whenever a check name is added or removed. Nothing in the repository
did that: #1095 did it by hand and #1259 did it with a throwaway script written
for the occasion, including the field pruning the test's docstring describes in
prose.

It matters because the recording is the calibration for the merge bar, so
getting it slightly wrong is invisible: a fixture edited to agree with the
thing it verifies still passes, and there is then nothing left that says what
GitHub actually replies (L48, L58).

    venv/bin/python tools/record_check_fixtures.py --pr 1341 [--write]

## What it refuses

A recording is only worth having if it is a picture of a pull request that
PASSED, judged by the same rules the wait uses:

  * every reported check settled and green, and
  * the reported checks are exactly the bar derived at that commit, through
    `wait_for_checks.expected_checks_at` rather than a second reading of the
    workflows written here (L41), and
  * every run and job names the head being recorded.

Any of those failing is a refusal that names which, because a recording taken
from a red or half-finished pull request would be a fixture asserting that a
broken reply is what green looks like, and every guard built on it would then
be green about the wrong thing.

## What it prunes

Each run's `repository`, `head_repository`, `pull_requests`, `head_commit`,
`actor` and `triggering_actor`, and each job's `steps`. Nothing reads them and
they are most of the bytes. The pruning lives here rather than in a docstring
telling somebody to do it by hand, which is what #1259 had to follow.

The workflow listing is pruned to what the bar reads. The file bodies are NOT
recorded: they are the checkout's own workflow files, and a copy of them beside
the tests would be a second version of the same thing to keep in step.

## The commit it came from

`gh_check_fixtures_meta.json` carries the repository, the pull request and the
head sha, written by the same run that wrote the fixtures. The tests read the
sha from there rather than carrying it as a literal somebody has to remember to
edit, which is one derivation instead of two (L70).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.wait_for_checks import (  # noqa: E402
    GhUnusable,
    UnreadableWorkflow,
    expected_checks_at,
    gh_json_any,
    poll_checks,
    verdict,
)

FIXTURES = REPO_ROOT / "tests" / "fixtures"
CHECKS = FIXTURES / "gh_pr_checks_real.json"
RUNS = FIXTURES / "gh_actions_runs_real.json"
JOBS = FIXTURES / "gh_actions_jobs_real.json"
LISTING = FIXTURES / "gh_workflow_listing_real.json"
META = FIXTURES / "gh_check_fixtures_meta.json"

#: Dropped from every run. Big, and nothing reads them.
RUN_NOISE = ("repository", "head_repository", "pull_requests", "head_commit",
             "actor", "triggering_actor")
#: Dropped from every job, for the same reason.
JOB_NOISE = ("steps",)
#: Kept from a workflow listing entry.
LISTING_KEPT = ("name", "path", "sha", "size", "type")


class NotWorthRecording(Exception):
    """The pull request is not a picture of a green run at one commit."""


def pr_checks(number: str, *,
              run: Callable[..., object] | None = None) -> list[dict]:
    """`gh pr checks`, as the fixture holds it.

    Still recorded even though the wait no longer judges by it: it is what the
    verdict rules were calibrated against and still are, so losing it would
    leave those rules with no evidence behind them at all.
    """
    run = run or subprocess.run
    done = run(["gh", "pr", "checks", str(number),
                "--json", "name,state,bucket,workflow"],
               capture_output=True, text=True, check=False)
    if done.returncode != 0 or not (done.stdout or "").strip():
        raise GhUnusable(
            f"gh pr checks {number} exited {done.returncode}: "
            f"{((done.stderr or '').strip() or '(silence)')[:200]}")
    rows = json.loads(done.stdout)
    if not isinstance(rows, list) or not rows:
        raise NotWorthRecording(
            f"gh pr checks {number} reported no rows at all, which is what it "
            "says in the window between a push and the checks being "
            "registered. There is nothing to record yet.")
    return sorted(rows, key=lambda row: (row.get("workflow", ""), row.get("name", "")))


def prune_runs(reply: dict) -> dict:
    runs = [{key: value for key, value in run.items() if key not in RUN_NOISE}
            for run in reply.get("workflow_runs", [])]
    return {"total_count": reply.get("total_count", len(runs)), "workflow_runs": runs}


def prune_jobs(reply: dict) -> dict:
    jobs = [{key: value for key, value in job.items() if key not in JOB_NOISE}
            for job in reply.get("jobs", [])]
    return {"total_count": reply.get("total_count", len(jobs)), "jobs": jobs}


def prune_listing(reply: object) -> list[dict]:
    if not isinstance(reply, list):
        raise NotWorthRecording(
            f"the workflow directory came back as {type(reply).__name__} "
            "rather than a listing")
    return [{key: entry.get(key) for key in LISTING_KEPT}
            for entry in reply if isinstance(entry, dict)]


def recording(number: str, *,
              api: Callable[[str], object] | None = None,
              checks: Callable[[str], list[dict]] | None = None,
              poll: Callable[[str], object] | None = None,
              bar: Callable[[str, str], set] | None = None) -> dict:
    """Every reply the fixtures hold, from one head, or a refusal saying why."""
    api = api or gh_json_any
    checks = checks or pr_checks
    poll = poll or poll_checks
    bar = bar or expected_checks_at

    reading = poll(number)
    head, repo = reading.head_sha, reading.repo
    if not head or not repo:
        raise NotWorthRecording(
            "the pull request named no head commit or no repository, so there "
            "is no one commit for these replies to be about")

    expected = bar(repo, head)
    answer = verdict(expected, reading.rows, reading.unfinished)
    if answer.state != "green":
        raise NotWorthRecording(
            f"pull request {number} at {head[:12]} is {answer.state}: "
            f"{answer.summary}. A fixture recorded from it would assert that "
            "this is what green looks like.")

    rows = checks(number)
    reported = {(row.get("workflow", ""), row.get("name", "")) for row in rows}
    wanted = {(check.workflow, check.name) for check in expected}
    if reported != wanted:
        missing = sorted(f"{w} / {n}" for w, n in wanted - reported)
        extra = sorted(f"{w} / {n}" for w, n in reported - wanted)
        raise NotWorthRecording(
            f"the reply about pull request {number} does not match the bar "
            f"derived at {head[:12]}: missing {missing or 'nothing'}, "
            f"unexpected {extra or 'nothing'}. One of the two is wrong and a "
            "recording cannot say which.")

    runs_reply = api(f"repos/{repo}/actions/runs?head_sha={head}&per_page=100")
    if not isinstance(runs_reply, dict):
        raise NotWorthRecording("the runs reply was not an object")
    jobs: dict[str, dict] = {}
    for run in runs_reply.get("workflow_runs", []):
        if str(run.get("head_sha")) != head:
            raise NotWorthRecording(
                f"a run at {str(run.get('head_sha'))[:12]} came back for "
                f"{head[:12]}, so these replies are not about one commit")
        reply = api(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100")
        if not isinstance(reply, dict):
            raise NotWorthRecording(f"the jobs reply for run {run['id']} was "
                                    "not an object")
        for job in reply.get("jobs", []):
            if str(job.get("head_sha")) != head:
                raise NotWorthRecording(
                    f"the job {job.get('name')!r} names "
                    f"{str(job.get('head_sha'))[:12]}, not {head[:12]}")
        jobs[str(run["id"])] = prune_jobs(reply)

    listing = prune_listing(api(f"repos/{repo}/contents/.github/workflows?ref={head}"))

    return {
        "meta": {"repo": repo, "pull_request": int(number), "head_sha": head,
                 "recorded_on": time.strftime("%Y-%m-%d"),
                 "checks": sorted(f"{w} / {n}" for w, n in wanted)},
        "checks": rows,
        "runs": prune_runs(runs_reply),
        "jobs": jobs,
        "listing": listing,
    }


def write(taken: dict, *, into: Path | None = None) -> list[Path]:
    """The four fixtures and the note saying where they came from."""
    root = into or FIXTURES
    written = []
    for path, body in ((root / CHECKS.name, taken["checks"]),
                       (root / RUNS.name, taken["runs"]),
                       (root / JOBS.name, taken["jobs"]),
                       (root / LISTING.name, taken["listing"]),
                       (root / META.name, taken["meta"])):
        path.write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")
        written.append(path)
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--pr", required=True,
                        help="the pull request to record, which must be green")
    parser.add_argument("--write", action="store_true",
                        help="write the fixtures; without it nothing changes")
    args = parser.parse_args(argv)

    try:
        taken = recording(str(args.pr))
    except (NotWorthRecording, GhUnusable, UnreadableWorkflow) as error:
        print(f"not recorded: {error}")
        return 1

    meta = taken["meta"]
    print(f"pull request {meta['pull_request']} at {meta['head_sha'][:12]} in "
          f"{meta['repo']}: {len(taken['checks'])} checks, "
          f"{len(taken['runs']['workflow_runs'])} runs, "
          f"{len(taken['jobs'])} job replies, "
          f"{len(taken['listing'])} workflow files")
    if not args.write:
        print("not written; pass --write to update the fixtures")
        return 0

    for path in write(taken):
        print(f"wrote {path.relative_to(REPO_ROOT)}")
    print("the fixtures now describe one green pull request at one commit. "
          "Run the suite: it is what says they still calibrate the bar.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
