"""#1466: the daily guard run says plainly when it did not sweep.

Since #1428 the full macOS sweep runs only when somebody starts it by hand. The
daily schedule still wakes the Linux `due` job, which went on printing "Shard(s)
1, 2, 3, 4, 5, 6, 7 have something to prove (tree not proved), so the sweep
runs." Then the shards were skipped and the run concluded green. No full sweep
ran from 2026-09-27, and every day read as though one had (L98).

Dan's call (2026-10-03): the sweep stays hand-started, and the daily run nags.
It says it did not sweep and when the last full sweep was, and once no sweep has
run for OVERDUE_AFTER it keeps one issue open saying so, closed again by the
next run after a sweep.
"""

from __future__ import annotations

import json
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

from tools import guard_sweep_history as history
from tools.check_guard_sweep_due import (
    OVERDUE_AFTER, LastSweepUnknown, decide_sweep, is_overdue)
from tools.guard_sweep_history import Sweep
from tools.say_when_the_sweep_is_overdue import (
    OVERDUE_TITLE, keep_the_overdue_issue_current)

NOW = datetime(2026, 10, 3, 7, 0, tzinfo=timezone.utc)
TREE = "a" * 40


def unproved():
    """A sweep decision with every shard due, the ordinary daily answer."""
    return decide_sweep(sha=TREE, shards=7, history=[], now=NOW)


# ── what the daily run says ──────────────────────────────────────────────────


def test_a_scheduled_run_never_claims_the_sweep_runs():
    said = unproved().say(event="schedule", last_sweep=NOW - timedelta(days=6),
                          now=NOW)
    assert "so the sweep runs" not in said
    assert "proved nothing" in said
    assert "gh workflow run guards.yml" in said


def test_it_names_when_the_last_full_sweep_ran():
    said = unproved().say(event="schedule",
                          last_sweep=datetime(2026, 9, 27, 9, 0, tzinfo=timezone.utc),
                          now=NOW)
    assert "2026-09-27" in said and "5 days ago" in said, said


def test_no_sweep_found_and_history_unreadable_say_different_things():
    none_found = unproved().say(event="schedule",
                                last_sweep=LastSweepUnknown.NONE_FOUND, now=NOW)
    unreadable = unproved().say(event="schedule",
                                last_sweep=LastSweepUnknown.UNREADABLE, now=NOW)
    assert "No full sweep was found" in none_found
    assert "could not be read" in unreadable
    assert none_found != unreadable


def test_a_requested_run_still_says_the_sweep_runs():
    said = unproved().say(event="workflow_dispatch",
                          last_sweep=NOW - timedelta(days=6), now=NOW)
    assert said.endswith("so the sweep runs.")


def test_a_quiet_tree_says_nothing_is_due_whatever_the_event():
    proved = [Sweep(run_id=1, head_sha=TREE, created_at=NOW - timedelta(days=1),
                    passed_shards=frozenset(range(1, 8)))]
    decision = decide_sweep(sha=TREE, shards=7, history=proved, now=NOW)
    said = decision.say(event="schedule", last_sweep=NOW - timedelta(days=1),
                        now=NOW)
    assert "starts no macOS runner" in said


# ── when it is overdue ────────────────────────────────────────────────────────


def test_a_sweep_inside_the_window_is_not_overdue():
    assert not is_overdue(NOW - OVERDUE_AFTER, now=NOW)


def test_a_sweep_past_the_window_is_overdue():
    assert is_overdue(NOW - OVERDUE_AFTER - timedelta(hours=1), now=NOW)


def test_no_sweep_found_at_all_is_overdue():
    assert is_overdue(LastSweepUnknown.NONE_FOUND, now=NOW)


def test_an_unreadable_history_accuses_nobody():
    # A query that failed is not evidence that nothing ran (L119).
    assert not is_overdue(LastSweepUnknown.UNREADABLE, now=NOW)


# ── finding the last full sweep ───────────────────────────────────────────────


def _run(run_id, day, passed):
    jobs = [{"name": f"full ({shard})",
             "steps": [{"name": history.PROOF_STEP, "conclusion": "success"}]}
            for shard in passed]
    run = {"id": run_id, "head_sha": TREE,
           "created_at": f"2026-09-{day:02d}T07:00:00Z"}
    return run, jobs


def test_the_last_sweep_is_read_from_scheduled_and_requested_runs(monkeypatch):
    """Not from the newest twenty runs of any kind: pull requests and the daily
    runs push a two-week-old sweep out of that page within days."""
    scheduled_sweep = _run(1, 27, [1, 2, 3])
    requested_sweep = _run(2, 4, [1, 2, 3, 4, 5, 6, 7])
    daily_noop = _run(3, 30, [])
    by_event = {"schedule": [daily_noop, scheduled_sweep],
                "workflow_dispatch": [requested_sweep]}
    jobs = {run["id"]: j for runs in by_event.values() for run, j in runs}
    asked = []

    def fake_gh(path):
        asked.append(path)
        if "/jobs" in path:
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return {"jobs": jobs[run_id]}
        event = path.split("event=")[1].split("&")[0]
        return {"workflow_runs": [run for run, _ in by_event[event]]}

    monkeypatch.setattr(history, "_gh", fake_gh)
    newest = history.newest_full_sweep(repo="o/r")

    assert newest == datetime(2026, 9, 27, 7, 0, tzinfo=timezone.utc)
    assert any("event=schedule" in p for p in asked)
    assert any("event=workflow_dispatch" in p for p in asked)


def test_no_full_sweep_in_either_history_is_none(monkeypatch):
    monkeypatch.setattr(history, "_gh", lambda path: (
        {"jobs": []} if "/jobs" in path
        else {"workflow_runs": [_run(9, 30, [])[0]]}))
    assert history.newest_full_sweep(repo="o/r") is None


# ── the one issue that says so ─────────────────────────────────────────────────


class FakeGitHub:
    def __init__(self, issues=None):
        self.issues = list(issues or [])
        self.calls: list[list[str]] = []

    def __call__(self, args):
        self.calls.append(args)
        action = args[2]
        if action == "list":
            return subprocess.CompletedProcess(args, 0, json.dumps(self.issues), "")
        if action == "create":
            title = args[args.index("--title") + 1]
            self.issues.append({"number": 900 + len(self.issues), "title": title})
        if action == "close":
            self.issues = [i for i in self.issues if i["number"] != int(args[3])]
        return subprocess.CompletedProcess(args, 0, "", "")

    def did(self, action):
        return [c for c in self.calls if c[2] == action]


def test_an_overdue_sweep_files_one_issue_and_then_comments():
    gh = FakeGitHub()
    keep_the_overdue_issue_current(overdue=True, said="no sweep for 20 days",
                                   run=gh)
    keep_the_overdue_issue_current(overdue=True, said="no sweep for 21 days",
                                   run=gh)
    assert len(gh.did("create")) == 1
    assert len(gh.did("comment")) == 1
    assert [i["title"] for i in gh.issues] == [OVERDUE_TITLE]


def test_a_sweep_that_ran_again_closes_the_issue():
    gh = FakeGitHub([{"number": 5, "title": OVERDUE_TITLE}])
    keep_the_overdue_issue_current(overdue=False, said="swept 1 day ago", run=gh)
    assert gh.did("close") and not gh.issues


def test_nothing_overdue_and_nothing_open_touches_nothing():
    gh = FakeGitHub([{"number": 5, "title": "somebody else's issue"}])
    keep_the_overdue_issue_current(overdue=False, said="swept", run=gh)
    assert not gh.did("create") and not gh.did("close") and not gh.did("comment")


@pytest.mark.parametrize("overdue", [True, False])
def test_the_issue_title_is_matched_exactly_not_searched(overdue):
    # A human's issue mentioning the sweep must never be commented on or closed.
    gh = FakeGitHub([{"number": 5, "title": OVERDUE_TITLE + " (notes)"}])
    keep_the_overdue_issue_current(overdue=overdue, said="x", run=gh)
    assert not gh.did("close") and not gh.did("comment")
