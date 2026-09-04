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
