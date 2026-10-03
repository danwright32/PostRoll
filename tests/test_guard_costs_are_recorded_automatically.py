"""#1099: nothing folded the daily sweep's readings into the cost record.

`tools/check_guards.py --timings` writes one shard's per-entry readings and
guards.yml uploads them as an artifact. Folding them into
`tests/fixtures/guard_entry_costs.json` is `tools/record_guard_costs.py
--from-run <id>`, a command somebody has to remember to type, which is a rule
living in a comment (L27).

`tests/test_guard_sweep_fits_its_deadline.py` was the safety net: it goes red
once the record covers less than 85% of the registry, and names the command.
That catches the drift late rather than preventing it, and it fails a suite for
a reason unrelated to whatever change is being made.

So a scheduled job records against the newest complete sweep and opens a pull
request when the record moves, and the readings arrive as a reviewed change
rather than as a push from a scheduled job.

## What this file checks, and what it cannot

It checks the piece that decides WHICH run to record from, which is ordinary
Python with the `gh` call injected, and it checks the workflow's shape: that it
never became a check a pull request waits on, that it opens a pull request
rather than committing to main, and that it says out loud which of its two modes
it took.

It cannot check that the job runs. Only a scheduled run can, and the record's
own `measured_from_run` is what shows it did.
"""

from __future__ import annotations

import json

import pytest

from tests.mac_build_setup import uncommented
from tools.guard_sweep_history import HistoryUnreadable, Sweep
from tools.record_guard_costs import (
    NoSweepFound, newest_sweep_run, record_from_run)
from tools.check_guard_sweep_due import SHARD_COUNT


WORKFLOW = ".github/workflows/record-guard-costs.yml"
ALL = frozenset(range(1, SHARD_COUNT + 1))


def _sweep(run_id: int, shards) -> Sweep:
    from datetime import datetime, timezone
    return Sweep(run_id=run_id, head_sha="a" * 40,
                 created_at=datetime(2026, 10, 1, tzinfo=timezone.utc),
                 passed_shards=frozenset(shards))


# ── which run gets recorded (#1467) ──────────────────────────────────────────
#
# It used to be "the newest SUCCESSFUL SCHEDULED run". Since #1428 the sweep is
# hand-started and the scheduled runs sweep nothing, so that answer was a run
# with no readings every day, refused, and green under continue-on-error: the
# record stood still from 2026-09-28 while the workflow said nothing.

def test_by_hand_it_records_from_the_newest_run_that_actually_swept() -> None:
    assert newest_sweep_run(find=lambda: _sweep(37200000001, ALL)) == "37200000001"


def test_no_run_that_swept_is_a_named_refusal_not_an_empty_answer() -> None:
    with pytest.raises(NoSweepFound, match="no run of guards.yml"):
        newest_sweep_run(find=lambda: None)


def test_a_history_that_could_not_be_read_is_not_read_as_no_sweep() -> None:
    def broken():
        raise HistoryUnreadable("HTTP 502")
    with pytest.raises(NoSweepFound, match="could not be read.*502"):
        newest_sweep_run(find=broken)


class Fetched:
    """Stands in for downloading a run's artifacts, recording what it was asked."""

    def __init__(self, paths=None, fails=False):
        self.paths, self.fails, self.asked = paths or [], fails, []

    def __call__(self, run_id, into):
        self.asked.append(run_id)
        if self.fails:
            raise SystemExit(f"gh could not download run {run_id}. Nothing was written.")
        return self.paths


def test_a_run_that_did_not_sweep_records_nothing_and_says_so(tmp_path, capsys):
    fetch = Fetched()
    code = record_from_run("37100000000", tmp_path / "rec.json",
                           sweep_of=lambda run_id: _sweep(37100000000, []),
                           fetch=fetch)
    assert code == 0
    assert fetch.asked == [], "it downloaded artifacts from a run that swept nothing"
    assert not (tmp_path / "rec.json").exists()
    assert "did not sweep" in capsys.readouterr().out


def test_a_whole_sweep_replaces_the_record(tmp_path, monkeypatch):
    from tools import record_guard_costs as rec
    took = []
    monkeypatch.setattr(rec, "_whole", lambda paths, record: took.append("whole") or 0)
    monkeypatch.setattr(rec, "_add", lambda paths, record: took.append("add") or 0)
    record_from_run("1", tmp_path / "rec.json",
                    sweep_of=lambda run_id: _sweep(1, ALL), fetch=Fetched(["x"]))
    assert took == ["whole"]


def test_a_sweep_of_some_shards_is_folded_in_rather_than_replacing(tmp_path, monkeypatch):
    """Since #1344 a sweep runs only the shards with something to prove, so a
    hand-started sweep is often partial. Replacing the record from it would
    price the whole registry from a fraction of it; `--add` exists for this."""
    from tools import record_guard_costs as rec
    took = []
    monkeypatch.setattr(rec, "_whole", lambda paths, record: took.append("whole") or 0)
    monkeypatch.setattr(rec, "_add", lambda paths, record: took.append("add") or 0)
    record_from_run("1", tmp_path / "rec.json",
                    sweep_of=lambda run_id: _sweep(1, [2, 5]), fetch=Fetched(["x"]))
    assert took == ["add"]


def test_a_run_that_swept_and_could_not_be_recorded_fails(tmp_path):
    """The case the workflow used to swallow: green while nothing was written."""
    with pytest.raises(SystemExit, match="could not download"):
        record_from_run("1", tmp_path / "rec.json",
                        sweep_of=lambda run_id: _sweep(1, ALL),
                        fetch=Fetched(fails=True))


def test_a_run_whose_jobs_could_not_be_read_fails(tmp_path):
    def broken(run_id):
        raise HistoryUnreadable("HTTP 404")
    with pytest.raises(SystemExit, match="404"):
        record_from_run("1", tmp_path / "rec.json", sweep_of=broken, fetch=Fetched())


def test_the_summary_says_when_the_record_was_last_replaced(tmp_path) -> None:
    from tools.record_guard_costs import describe
    path = tmp_path / "rec.json"
    path.write_text(json.dumps({"measured_on": "2026-09-27",
                                "measured_from_run": "36319996693"}))
    assert "2026-09-27, run 36319996693" in describe(path)


@pytest.mark.parametrize("contents", [None, "{not json"])
def test_an_unreadable_record_is_said_rather_than_crashing_the_summary(
        tmp_path, contents) -> None:
    from tools.record_guard_costs import describe
    path = tmp_path / "rec.json"
    if contents is not None:
        path.write_text(contents)
    assert describe(path).startswith("The guard cost record could not be read")


def test_the_summary_asks_the_recorder_for_the_age(workflow: str) -> None:
    assert "record_guard_costs.py --describe" in uncommented(workflow)


# ── the workflow's shape ─────────────────────────────────────────────────────

@pytest.fixture
def workflow() -> str:
    from pathlib import Path
    path = Path(__file__).resolve().parent.parent / WORKFLOW
    assert path.exists(), f"{WORKFLOW} does not exist, so nothing folds the readings in"
    return path.read_text()


def test_it_never_becomes_a_check_a_pull_request_waits_on(workflow: str) -> None:
    """`wait_for_checks.py` derives the bar from the workflow files, and a new
    check name can only go green once its recorded reply already holds it, so
    adding one costs a knowingly red merge (#1074, L48)."""
    assert "pull_request:" not in uncommented(workflow)


# ── it follows the sweep rather than a clock (#1262) ─────────────────────────
#
# It was scheduled at 09:00, "two hours after the sweep's own 07:00". The
# premise was false: measured 2026-09-03, the last six scheduled runs of the
# sweep actually STARTED at 11:55, 11:57, 12:21 and 14:50, because GitHub delays
# scheduled workflows by hours under load. So the recorder ran hours BEFORE the
# thing it was written to follow, every day, and the record stayed a day behind
# while a confident sentence beside the cron said otherwise (L386).


def _sweep_name() -> str:
    """The sweep's declared name, read from ITS file rather than retyped here.

    A `workflow_run` trigger matches on the upstream workflow's NAME, and a
    name that matches nothing fires never: the recorder would simply stop, and
    a workflow that never runs looks exactly like one with nothing to do (L100,
    L98).
    """
    from pathlib import Path
    text = (Path(__file__).resolve().parent.parent
            / ".github" / "workflows" / "guards.yml").read_text()
    first = next(line for line in text.splitlines() if line.startswith("name:"))
    return first.split("name:", 1)[1].strip()


def test_it_starts_when_the_sweep_finishes_rather_than_at_a_clock_time(
        workflow: str) -> None:
    body = uncommented(workflow)
    assert "workflow_run:" in body, (
        "nothing ties this to the sweep, so whatever time it is given is a "
        "guess about how late GitHub will start a scheduled job (#1262)")
    assert "cron:" not in body, (
        "a clock time is still here beside the trigger that makes it "
        "unnecessary, so the run that fires first is whichever the platform "
        "gets to, and one of the two is always recording nothing")


def _followed_workflows(workflow: str) -> list[str]:
    """The names in the `workflow_run` trigger's own list.

    Parsed rather than searched for. Asking whether the sweep's name APPEARS in
    the file is answered by any longer name containing it: written that way
    first, this guard SURVIVED its mutation, because "Guard proofs sweep"
    contains "Guard proofs" and GitHub would have matched neither (L178).
    """
    import re
    line = re.search(r"^\s*workflows:\s*\[(.*)\]\s*$",
                     uncommented(workflow), re.M)
    assert line, ("the workflow_run trigger carries no workflows list, so it "
                  "follows nothing and this check reads an empty set (L98)")
    return [name.strip().strip('"\'') for name in line.group(1).split(",")]


def test_it_names_the_sweep_by_the_name_the_sweep_declares(workflow: str) -> None:
    assert _followed_workflows(workflow) == [_sweep_name()], (
        f"the trigger follows {_followed_workflows(workflow)}, and "
        f".github/workflows/guards.yml calls itself {_sweep_name()!r}. A name "
        "that is not exactly that matches no workflow and fires never")


def test_it_does_not_fire_on_every_pull_request(workflow: str) -> None:
    """The trap in `workflow_run`: it fires for EVERY trigger of the upstream
    workflow, and the sweep's `changed` job runs on every pull request. Without
    a gate this would record from a run that proved the entries one diff
    touched, and `--from` REPLACES the record, so the whole registry would be
    priced from a handful of entries."""
    body = uncommented(workflow)
    assert "workflow_run.event == 'schedule'" in body, (
        "the job does not check WHICH trigger produced the sweep it is "
        "following, so it records from the per-pull-request run too")
    assert "'pull_request'" not in body.split("if: >-")[1].split("timeout-minutes")[0]


def test_it_follows_a_hand_started_sweep(workflow: str) -> None:
    """Since #1428 a hand-started run is the only kind that sweeps, so a
    recorder that admitted only scheduled runs could never record again."""
    assert "workflow_run.event == 'workflow_dispatch'" in uncommented(workflow)


def test_it_records_the_run_it_followed_not_the_newest_of_some_kind(
        workflow: str) -> None:
    assert "--from-upstream-run ${{ github.event.workflow_run.id }}" in uncommented(workflow)


def test_a_recording_that_failed_turns_the_run_red(workflow: str) -> None:
    """A run with nothing to record exits 0 on its own now, so nothing needs
    `continue-on-error`, which is what kept the run green while it wrote nothing
    from 2026-09-28 (#1467)."""
    assert "continue-on-error" not in uncommented(workflow)


def test_it_does_not_record_from_a_sweep_that_failed(workflow: str) -> None:
    assert "workflow_run.conclusion == 'success'" in uncommented(workflow), (
        "a failed sweep would be recorded from, and a shard that died early "
        "measured the entries it reached and nothing about the rest (L331)")


def test_it_can_still_be_asked_for_by_hand(workflow: str) -> None:
    """The gate must not exclude a manual run. A record that has drifted should
    be fixable now rather than at the next sweep."""
    body = uncommented(workflow)
    assert "workflow_dispatch:" in body
    assert "github.event_name == 'workflow_dispatch'" in body, (
        "the schedule gate refuses a dispatched run too, so the manual trigger "
        "is a control that does nothing (L109)")


def test_it_opens_a_pull_request_rather_than_committing_to_main(workflow: str) -> None:
    body = uncommented(workflow)
    assert "propose_recorded_change.sh" in body, (
        "the readings are not proposed through the shared script, so this "
        "workflow carries its own copy of the push, and the copy it used to "
        "carry was one git refuses on the second run of any day (#1311)")
    assert "git push origin main" not in body


def test_it_records_through_the_recorder_rather_than_writing_the_file(
        workflow: str) -> None:
    """Every refusal the recorder has (readings from two runs, a duplicate
    entry, a zero, an empty file, a shard that ran out of time) lives in that
    tool. A job that wrote the record itself would have none of them."""
    assert "record_guard_costs.py" in uncommented(workflow)


def test_it_says_which_mode_it_took(workflow: str) -> None:
    """Opening the pull request needs a token the default one cannot stand in
    for: a pull request opened with GITHUB_TOKEN starts no workflow runs, so it
    would carry no checks and could never be merged.

    The job therefore has two outcomes, and a run that could not open one must
    not look like a run that found nothing to record (L98). It uploads the
    record it computed and says so.
    """
    body = uncommented(workflow)
    assert "GITHUB_STEP_SUMMARY" in body, (
        "the job reports nothing anybody reads, so which of its two modes it "
        "took is only in a log nobody opens")
    assert "upload-artifact" in body, (
        "a run that could not open a pull request throws its measurement away")


def test_one_run_is_read_and_summarised_by_what_it_proved(monkeypatch) -> None:
    from tools import guard_sweep_history as history
    asked = []

    def fake_gh(path):
        asked.append(path)
        if path.endswith("/jobs?per_page=100"):
            return {"jobs": [{"name": "full (2)", "steps": [
                {"name": history.PROOF_STEP, "conclusion": "success"}]}]}
        return {"id": 42, "head_sha": "b" * 40,
                "created_at": "2026-10-01T07:00:00Z"}

    monkeypatch.setattr(history, "_gh", fake_gh)
    sweep = history.sweep_of(42, repo="o/r")
    assert sweep.run_id == 42 and sweep.passed_shards == frozenset({2})
    assert asked[0] == "repos/o/r/actions/runs/42"


def test_a_run_that_cannot_be_read_is_refused_not_read_as_unswept(monkeypatch) -> None:
    from tools import guard_sweep_history as history

    def broken(path):
        raise HistoryUnreadable("HTTP 404: run not found")

    monkeypatch.setattr(history, "_gh", broken)
    with pytest.raises(HistoryUnreadable, match="404"):
        history.sweep_of(42, repo="o/r")
