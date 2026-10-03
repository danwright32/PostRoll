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


def swept(at, shards=None) -> Sweep:
    """The last sweep, as the history helper returns it: every shard unless
    told otherwise."""
    return Sweep(run_id=7, head_sha=TREE, created_at=at,
                 passed_shards=frozenset(range(1, 8) if shards is None else shards))


def unproved():
    """A sweep decision with every shard due, the ordinary daily answer."""
    return decide_sweep(sha=TREE, shards=7, history=[], now=NOW)


# ── what the daily run says ──────────────────────────────────────────────────


def test_a_scheduled_run_never_claims_the_sweep_runs():
    said = unproved().say(event="schedule", last_sweep=swept(NOW - timedelta(days=6)),
                          now=NOW)
    assert "so the sweep runs" not in said
    assert "proved nothing" in said
    assert "gh workflow run guards.yml" in said


def test_it_names_when_the_last_full_sweep_ran():
    said = unproved().say(event="schedule",
                          last_sweep=swept(datetime(2026, 9, 27, 9, 0, tzinfo=timezone.utc),
                                           shards=[1, 2, 3]),
                          now=NOW)
    assert "2026-09-27" in said and "5 days ago" in said, said
    assert "proving 3 of 7 shards" in said, said


def test_no_sweep_found_and_history_unreadable_say_different_things():
    none_found = unproved().say(event="schedule",
                                last_sweep=LastSweepUnknown.NONE_FOUND, now=NOW)
    unreadable = unproved().say(event="schedule",
                                last_sweep=LastSweepUnknown.UNREADABLE, now=NOW)
    assert "No sweep was found" in none_found
    assert "could not be read" in unreadable
    assert none_found != unreadable


def test_a_requested_run_still_says_the_sweep_runs():
    said = unproved().say(event="workflow_dispatch",
                          last_sweep=swept(NOW - timedelta(days=6)), now=NOW)
    assert said.endswith("so the sweep runs.")


def test_a_quiet_tree_says_nothing_is_due_whatever_the_event():
    proved = [Sweep(run_id=1, head_sha=TREE, created_at=NOW - timedelta(days=1),
                    passed_shards=frozenset(range(1, 8)))]
    decision = decide_sweep(sha=TREE, shards=7, history=proved, now=NOW)
    said = decision.say(event="schedule", last_sweep=swept(NOW - timedelta(days=1)),
                        now=NOW)
    assert "starts no macOS runner" in said


# ── when it is overdue ────────────────────────────────────────────────────────


def test_a_sweep_inside_the_window_is_not_overdue():
    assert is_overdue(swept(NOW - OVERDUE_AFTER), now=NOW) is False


def test_a_sweep_past_the_window_is_overdue():
    assert is_overdue(swept(NOW - OVERDUE_AFTER - timedelta(hours=1)), now=NOW) is True


def test_no_sweep_found_at_all_is_overdue():
    assert is_overdue(LastSweepUnknown.NONE_FOUND, now=NOW)


def test_an_unreadable_history_accuses_nobody():
    # A query that failed is not evidence that nothing ran (L119).
    # Neither overdue nor on time: None, which the nag step leaves alone.
    assert is_overdue(LastSweepUnknown.UNREADABLE, now=NOW) is None


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

    assert newest.created_at == datetime(2026, 9, 27, 7, 0, tzinfo=timezone.utc)
    assert newest.run_id == 1 and newest.passed_shards == frozenset({1, 2, 3})
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


# ── when GitHub cannot be asked ───────────────────────────────────────────────


def test_an_unreadable_history_raises_rather_than_reading_as_no_sweep(monkeypatch):
    def broken(path):
        raise history.HistoryUnreadable("gh api failed: HTTP 502")

    monkeypatch.setattr(history, "_gh", broken)
    with pytest.raises(history.HistoryUnreadable, match="502"):
        history.newest_full_sweep(repo="o/r")


def test_the_daily_run_maps_an_unreadable_history_to_its_own_answer(monkeypatch, capsys):
    from tools import check_guard_sweep_due as due

    def broken(*, repo=None):
        raise history.HistoryUnreadable("rate limited")

    monkeypatch.setattr(due, "newest_full_sweep", broken)
    assert due._last_sweep("o/r") is LastSweepUnknown.UNREADABLE
    assert "could not be read: rate limited" in capsys.readouterr().out


class BrokenGitHub(FakeGitHub):
    """A `gh` whose every call fails, as on a revoked token or an outage."""

    def __call__(self, args):
        self.calls.append(args)
        return subprocess.CompletedProcess(args, 1, "", "HTTP 401: Bad credentials")


@pytest.mark.parametrize("overdue", [True, False])
def test_a_github_that_cannot_be_asked_is_refused_by_name(overdue):
    from tools.say_when_the_sweep_is_overdue import CannotAsk
    with pytest.raises(CannotAsk, match="Bad credentials"):
        keep_the_overdue_issue_current(overdue=overdue, said="x",
                                       run=BrokenGitHub())


def test_a_nag_that_could_not_be_delivered_turns_the_step_red(monkeypatch, capsys):
    from tools import say_when_the_sweep_is_overdue as nag
    from tools.say_when_the_sweep_is_overdue import CannotAsk

    def refuse(**_):
        raise CannotAsk("gh issue list failed: HTTP 401")

    monkeypatch.setattr(nag, "keep_the_overdue_issue_current", refuse)
    assert nag.main(["--overdue", "true", "--said", "x"]) == 1
    assert "::error::" in capsys.readouterr().out


class VanishingGitHub(FakeGitHub):
    """Creates the issue, then lists nothing: it is not where it was put."""

    def __call__(self, args):
        if args[2] == "list":
            self.calls.append(args)
            return subprocess.CompletedProcess(args, 0, "[]", "")
        return super().__call__(args)


def test_an_issue_missing_right_after_it_was_filed_is_refused():
    from tools.say_when_the_sweep_is_overdue import CannotAsk
    with pytest.raises(CannotAsk, match="not in the open list"):
        keep_the_overdue_issue_current(overdue=True, said="x",
                                       run=VanishingGitHub())


class RacingGitHub(FakeGitHub):
    """Two daily runs filing at the same moment: the create lands twice."""

    def __call__(self, args):
        result = super().__call__(args)
        if args[2] == "create":
            self.issues.append({"number": 999, "title": args[args.index("--title") + 1]})
        return result


def test_two_runs_filing_at_once_leave_one_issue():
    gh = RacingGitHub()
    did, keeper = keep_the_overdue_issue_current(overdue=True, said="x", run=gh)
    assert did == "deduplicated"
    assert [i["number"] for i in gh.issues] == [keeper]


# ── review fixes ──────────────────────────────────────────────────────────────


def test_an_unknown_answer_never_closes_the_overdue_issue():
    """A failed read closing a real overdue issue with "the sweep has run
    again" would be the worst wrong answer this has (L119)."""
    gh = FakeGitHub([{"number": 5, "title": OVERDUE_TITLE}])
    did, _ = keep_the_overdue_issue_current(overdue=None, said="x", run=gh)
    assert "could not tell" in did
    assert gh.calls == [], "it asked GitHub anything at all"


def test_the_nag_step_accepts_unknown(monkeypatch):
    from tools import say_when_the_sweep_is_overdue as nag
    seen = []
    monkeypatch.setattr(nag, "keep_the_overdue_issue_current",
                        lambda **kw: seen.append(kw["overdue"]) or ("x", None))
    assert nag.main(["--overdue", "unknown", "--said", "x"]) == 0
    assert seen == [None]


def test_the_title_quotes_no_threshold():
    assert not any(ch.isdigit() for ch in OVERDUE_TITLE)
    assert "week" not in OVERDUE_TITLE and "day" not in OVERDUE_TITLE


def test_the_newest_sweep_stops_at_the_first_run_that_proved_a_shard(monkeypatch):
    """Newest first: older runs are not asked about once one has proved."""
    newest, older = _run(1, 27, [1, 2]), _run(2, 20, [1, 2, 3, 4, 5, 6, 7])
    asked_jobs = []

    def fake_gh(path):
        if "/jobs" in path:
            run_id = int(path.split("/runs/")[1].split("/")[0])
            asked_jobs.append(run_id)
            return {"jobs": {1: newest[1], 2: older[1]}[run_id]}
        if "event=schedule" in path:
            return {"workflow_runs": [older[0], newest[0]]}
        return {"workflow_runs": []}

    monkeypatch.setattr(history, "_gh", fake_gh)
    assert history.newest_full_sweep(repo="o/r").run_id == 1
    assert asked_jobs == [1]


def test_the_message_is_written_so_a_newline_cannot_end_it(monkeypatch, tmp_path):
    from tools import check_guard_sweep_due as due
    monkeypatch.setattr(due, "_history", lambda *a: [])
    monkeypatch.setattr(due, "_last_sweep",
                        lambda repo: LastSweepUnknown.UNREADABLE)
    out = tmp_path / "out"
    due.main(["--shards", "--sha", TREE, "--event", "schedule",
              "--output", str(out)])
    # Parsed as GitHub parses it: `key=value` lines, and a `key<<DELIM` value
    # running to the line holding only DELIM.
    lines = out.read_text().splitlines()
    outputs, i = {}, 0
    while i < len(lines):
        if "<<" in lines[i]:
            key, delim = lines[i].split("<<", 1)
            end = lines.index(delim, i + 1)
            outputs[key] = "\n".join(lines[i + 1:end])
            i = end + 1
        else:
            key, value = lines[i].split("=", 1)
            outputs[key] = value
            i += 1
    assert outputs["overdue"] == "unknown"
    assert outputs["said"].startswith("Shard(s)"), outputs
