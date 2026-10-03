"""What the guard sweep has actually PROVED, read off its own run history (#989).

Two separate questions in this repository are answered from the same evidence,
and before this they were answered from two different readings of it:

`tools/check_guard_sweep_due.py` asks whether THIS tree still needs proving,
which is what lets a requested sweep skip the shards already proved.

It used to key on a RUN, and that reading stopped being true the moment the
sweep's own steps became conditional. A run that skipped its proof is still a
run, still concluded `success`, and still carries the tree's sha, so by that
reading a workflow that proves nothing for a month reads as a tree already
proved (L98, L106).

So the unit here is a STEP conclusion: the proof step having executed AND
succeeded. A red shard is an unproved share of the registry, and the next sweep
should re-take it rather than treat the attempt as the answer.

A second reader, the freshness check asking whether a SCHEDULED sweep was still
happening, also read whether a step ran at all. It went with the schedule in
#1428, and so did that field.

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
    #: Shards whose proof step executed and succeeded.
    passed_shards: frozenset[int]


def shard_of_job_name(name: str) -> int | None:
    """Which shard a job name is, or None when it is not a sweep shard.

    A matrix over `shard: [1, 2, 3, 4, 5, 6]` names its jobs `full (1)` and so on. The
    `changed` job and every job in another workflow have to answer None here, or
    one job's success would stand in for a shard's (L70).
    """
    match = re.fullmatch(rf"{re.escape(SWEEP_JOB)} \((\d+)\)", name.strip())
    return int(match.group(1)) if match else None


def proved(job: dict) -> bool:
    """Whether the proof step inside one job executed and succeeded.

    A job with no step by that name answers False: the step could have been
    renamed, and reporting that as a proof would be the one wrong answer
    available here.
    """
    for step in job.get("steps") or []:
        if str(step.get("name") or "").strip() != PROOF_STEP:
            continue
        return str(step.get("conclusion") or "").lower() == "success"
    return False


def _stamp(raw: str) -> datetime | None:
    try:
        when = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except (ValueError, AttributeError, TypeError):
        return None
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def sweeps_from_jobs(run: dict, jobs: list[dict]) -> Sweep:
    """One run plus its jobs, reduced to what that run proved."""
    passed: set[int] = set()
    for job in jobs:
        shard = shard_of_job_name(str(job.get("name") or ""))
        if shard is not None and proved(job):
            passed.add(shard)
    return Sweep(
        run_id=int(run.get("id") or 0),
        head_sha=str(run.get("head_sha") or ""),
        created_at=_stamp(run.get("created_at", "")),
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


def recent_sweeps(*, repo: str | None = None, limit: int = 20,
                  skip_run_id: int | None = None) -> list[Sweep]:
    """The most recent completed guard-workflow runs, newest first."""
    name = _repo(repo)
    query = (f"repos/{name}/actions/workflows/{WORKFLOW_FILE}/runs"
             f"?status=completed&per_page={limit}")
    runs = list(_gh(query).get("workflow_runs") or [])
    return _summarise(name, runs, skip_run_id=skip_run_id)


#: The events a full sweep can run under. `workflow_dispatch` since #1428, when
#: the sweep became hand-started; `schedule` for the sweeps before it.
SWEEP_EVENTS = ("schedule", "workflow_dispatch")


def newest_full_sweep(*, repo: str | None = None,
                      limit: int = 20) -> Sweep | None:
    """The newest run that actually proved a shard, or None.

    The whole run rather than its date, because the guard cost recorder needs
    its id and which shards it proved (#1467) and the daily run needs its date.

    Asked per event rather than of the newest runs of any kind (#1466). Pull
    requests and the daily runs that sweep nothing fill a page of recent runs
    within days, so a sweep two weeks old would fall off it and read as no
    sweep at all, the very case this exists to report. Hand-started runs are
    rare, so a page of them reaches back a long way.

    Raises HistoryUnreadable when either history cannot be read: an unanswered
    query is not evidence that nothing ran (L119).
    """
    name = _repo(repo)
    newest: Sweep | None = None
    for event in SWEEP_EVENTS:
        query = (f"repos/{name}/actions/workflows/{WORKFLOW_FILE}/runs"
                 f"?event={event}&status=completed&per_page={limit}")
        runs = list(_gh(query).get("workflow_runs") or [])
        # Newest first, as GitHub lists them, so the first run that proved a
        # shard is this event's answer. Each run costs a jobs request, and the
        # daily runs that swept nothing would otherwise cost one each, every
        # day, for an answer already in hand.
        runs.sort(key=lambda run: str(run.get("created_at") or ""), reverse=True)
        for run in runs:
            sweep = _summarise(name, [run], skip_run_id=None)[0]
            if sweep.passed_shards and sweep.created_at is not None:
                if newest is None or sweep.created_at > newest.created_at:
                    newest = sweep
                break
    return newest
