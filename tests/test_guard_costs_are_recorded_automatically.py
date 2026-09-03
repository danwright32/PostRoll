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
from tools.record_guard_costs import NoSweepFound, newest_sweep_run


WORKFLOW = ".github/workflows/record-guard-costs.yml"


def _gh(reply: str, code: int = 0):
    asked: list[list[str]] = []

    def run(args: list[str]) -> tuple[int, str]:
        asked.append(args)
        return code, reply

    run.asked = asked  # type: ignore[attr-defined]
    return run


RUNS = json.dumps([
    {"databaseId": 33409212726, "conclusion": "success",
     "createdAt": "2026-09-02T07:31:00Z"},
])


# ── which run gets recorded ──────────────────────────────────────────────────

def test_it_records_from_the_newest_successful_scheduled_sweep() -> None:
    gh = _gh(RUNS)

    assert newest_sweep_run(run=gh) == "33409212726"

    asked = " ".join(gh.asked[0])
    assert "guards.yml" in asked, "it asked about some other workflow"
    assert "schedule" in asked, (
        "it did not scope the search to SCHEDULED runs, and the per-pull-request "
        "`changed` job proves only the entries one diff touched, so its readings "
        "would replace a whole-registry record with a handful of entries")


def test_no_sweep_at_all_is_a_named_refusal_not_an_empty_answer() -> None:
    """A repository whose sweep has not run and a repository whose sweep found
    nothing are different, and the second reads as a healthy record (L98)."""
    with pytest.raises(NoSweepFound) as raised:
        newest_sweep_run(run=_gh("[]"))
    assert "no successful" in str(raised.value).lower()


def test_a_failed_gh_call_is_not_read_as_no_sweep() -> None:
    """The two have to be told apart, or a broken token quietly means the job
    reports nothing to record, every day, forever (L11)."""
    with pytest.raises(NoSweepFound) as raised:
        newest_sweep_run(run=_gh("gh: not logged in", code=4))
    assert "4" in str(raised.value)


def test_output_that_is_not_json_is_refused_rather_than_guessed() -> None:
    with pytest.raises(NoSweepFound):
        newest_sweep_run(run=_gh("<html>a proxy error page</html>"))


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


def test_it_runs_on_a_schedule_of_its_own(workflow: str) -> None:
    body = uncommented(workflow)
    assert "schedule:" in body and "cron:" in body, (
        "nothing runs this, so the record ages exactly as it did before")
    assert "workflow_dispatch:" in body, (
        "there is no way to ask for it, so a record that has drifted waits a "
        "day for the next cron rather than being fixed now")


def test_it_opens_a_pull_request_rather_than_committing_to_main(workflow: str) -> None:
    body = uncommented(workflow)
    assert "gh pr create" in body, (
        "the readings would arrive as a push from a scheduled job rather than "
        "as a reviewed change")
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
