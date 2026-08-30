"""What the guard sweep has actually PROVED, read off its own run history (#989).

Two separate questions in this repository are answered from the same evidence,
and before this they were answered from two different readings of it:

* `tools/check_guard_sweep_due.py` asks whether THIS tree still needs proving,
  which is what makes a daily sweep cheaper than a per-merge one.
* `tools/check_guard_sweep_freshness.py` asks whether the sweep is still
  HAPPENING at all, which is what makes a schedule safe to depend on (#554).

Both used to key on a RUN: the gate would have keyed on a run at this sha, and
the freshness check keyed on a successful scheduled run. That reading stopped
being true the moment the sweep's own steps became conditional. A run that
skipped its proof is still a run, still concluded `success`, and still carries
the tree's sha, so by that reading a workflow that proves nothing for a month
reads as a tree already proved and a schedule in perfect health (L98, L106).

So the unit here is a STEP conclusion, and there are two of them, deliberately
kept apart (L261):

* `ran` is the step having executed at all, which is the freshness question.
* `passed` is it having executed and succeeded, which is the gate's question,
  because a red shard is an unproved share of the registry and tomorrow's run
  should re-take it rather than treat the attempt as the answer.

Read through `gh api` so it uses the token the workflow already has, and every
failure raises rather than returning an empty history: a query that could not be
asked and a sweep that never happened are different facts, and the second is the
one that would silently switch this off (L119).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone

#: The step inside the `full` job that does the proving. A proof is this step
#: having run, never the job or the run having concluded, for the reason in the
#: module docstring.
#:
#: `tests/test_guard_sweep_due.py` asserts the workflow still contains a step by
#: this name. A name that matches nothing here does not fail: it reports every
#: tree unproved and every schedule dead, which is the safe direction and an
#: expensive one to leave in place unnoticed (L100).
PROOF_STEP = "Re-prove this shard of the guards"

#: The job the shards are, as GitHub names them once the matrix has expanded.
SWEEP_JOB = "full"

WORKFLOW_FILE = "guards.yml"


class HistoryUnreadable(Exception):
    """The run history could not be read, which is not the same as it being
    empty. Never allowed to collapse into an empty list."""


@dataclass(frozen=True)
class Sweep:
    """One run of the guard workflow, summarised by what its shards did."""

    run_id: int
    head_sha: str
    #: None when the run's stamp could not be parsed. Never defaulted to now:
    #: an unreadable value landing on the permissive side of an age comparison
    #: is the one way a check reports healthy for a reason unrelated to the
    #: truth (L50).
    created_at: datetime | None
    event: str
    #: Shards whose proof step executed, whatever it concluded.
    ran_shards: frozenset[int]
    #: Shards whose proof step executed and succeeded.
    passed_shards: frozenset[int]


def shard_of_job_name(name: str) -> int | None:
    """Which shard a job name is, or None when it is not a sweep shard.

    A matrix over `shard: [1, 2, 3, 4]` names its jobs `full (1)` and so on. The
    `changed` job and every job in another workflow have to answer None here, or
    one job's success would stand in for a shard's (L70).
    """
    match = re.fullmatch(rf"{re.escape(SWEEP_JOB)} \((\d+)\)", name.strip())
    return int(match.group(1)) if match else None


def proof_outcome(job: dict) -> tuple[bool, bool]:
    """(ran, passed) for the proof step inside one job.

    A job with no step by that name answers (False, False): the step could have
    been renamed, and reporting that as a proof would be the one wrong answer
    available here.
    """
    for step in job.get("steps") or []:
        if str(step.get("name") or "").strip() != PROOF_STEP:
            continue
        conclusion = str(step.get("conclusion") or "").lower()
        if conclusion in ("skipped", "", "cancelled"):
            return False, False
        return True, conclusion == "success"
    return False, False


def _stamp(raw: str) -> datetime | None:
    try:
        when = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except (ValueError, AttributeError, TypeError):
        return None
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def sweeps_from_jobs(run: dict, jobs: list[dict]) -> Sweep:
    """One run plus its jobs, reduced to what that run proved."""
    ran: set[int] = set()
    passed: set[int] = set()
    for job in jobs:
        shard = shard_of_job_name(str(job.get("name") or ""))
        if shard is None:
            continue
        did_run, did_pass = proof_outcome(job)
        if did_run:
            ran.add(shard)
        if did_pass:
            passed.add(shard)
    return Sweep(
        run_id=int(run.get("id") or 0),
        head_sha=str(run.get("head_sha") or ""),
        created_at=_stamp(run.get("created_at", "")),
        event=str(run.get("event") or ""),
        ran_shards=frozenset(ran),
        passed_shards=frozenset(passed),
    )


# ── asking GitHub ─────────────────────────────────────────────────────────────


def _gh(path: str) -> dict:
    try:
        done = subprocess.run(
            ["gh", "api", "-H", "Accept: application/vnd.github+json", path],
            capture_output=True, text=True, check=False)
    except FileNotFoundError as error:
        raise HistoryUnreadable("gh is not installed or not on PATH") from error
    if done.returncode != 0 or not done.stdout.strip():
        raise HistoryUnreadable(
            f"gh api {path} exited {done.returncode}: "
            f"{(done.stderr.strip() or done.stdout.strip())[:200] or '(silence)'}")
    try:
        reply = json.loads(done.stdout)
    except json.JSONDecodeError as error:
        raise HistoryUnreadable(f"gh api {path} printed something that is not "
                                f"JSON: {error}") from error
    if not isinstance(reply, dict):
        raise HistoryUnreadable(
            f"gh api {path} returned {type(reply).__name__}, not an object")
    return reply


def _repo(repo: str | None) -> str:
    name = repo or os.environ.get("GITHUB_REPOSITORY") or ""
    if not name:
        raise HistoryUnreadable(
            "no repository to ask about: pass --repo or set GITHUB_REPOSITORY")
    return name


def _summarise(repo: str, runs: list[dict], *, skip_run_id: int | None) -> list[Sweep]:
    history: list[Sweep] = []
    for run in runs:
        if skip_run_id is not None and int(run.get("id") or 0) == skip_run_id:
            # The run asking the question is still in flight, so its own proof
            # step has not concluded. Excluded by id rather than by status, so
            # this cannot depend on how GitHub reports a run about itself.
            continue
        jobs = _gh(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100")
        history.append(sweeps_from_jobs(run, list(jobs.get("jobs") or [])))
    return history


def sweeps_at(sha: str, *, repo: str | None = None,
              skip_run_id: int | None = None) -> list[Sweep]:
    """Every guard-workflow run recorded against one commit."""
    name = _repo(repo)
    runs = _gh(f"repos/{name}/actions/runs?head_sha={sha}&per_page=100")
    ours = [run for run in (runs.get("workflow_runs") or [])
            if str(run.get("path") or "").endswith(WORKFLOW_FILE)]
    return _summarise(name, ours, skip_run_id=skip_run_id)


def recent_sweeps(*, repo: str | None = None, event: str | None = None,
                  limit: int = 20, skip_run_id: int | None = None) -> list[Sweep]:
    """The most recent completed guard-workflow runs, newest first."""
    name = _repo(repo)
    query = (f"repos/{name}/actions/workflows/{WORKFLOW_FILE}/runs"
             f"?status=completed&per_page={limit}")
    if event:
        query += f"&event={event}"
    runs = list(_gh(query).get("workflow_runs") or [])
    return _summarise(name, runs, skip_run_id=skip_run_id)
