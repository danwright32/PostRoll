"""#1261: nothing re-recorded the Swift suite count, so the floor went slack.

`tools/suite_counts.py` refuses a Swift leg that ran far fewer tests than the
suite is known to hold, deriving the floor from
`tests/fixtures/swift_suite_count.json` with a 2% tolerance. That record said
2,599, measured 2026-08-29. The suite ran 2,965 on 2026-09-04, so the floor was
2,547 and a run could silently lose 418 tests, 14% of the suite, and still be
waved through as full.

Losing a worker's share is precisely the failure parallel testing adds, and this
floor is the only thing that tells a full run from a partial one: a short run
reports a well-formed total, exits green and prints TEST SUCCEEDED (L98). A
floor that drifts down as the suite grows away from it reads as an active
safeguard while refusing less and less (L182).

Re-recording it is one command somebody has to remember to type, which is a rule
living in a comment (L27), and #1099 fixed the same shape for the guard cost
record. So a job records against the newest green run of the Swift suite and
opens a pull request when the record has gone slack, and the number arrives as a
reviewed change rather than as a push from a scheduled job.

## What this file checks, and what it cannot

It checks the piece that decides WHICH run to record from and WHETHER the
record has drifted far enough to be worth proposing, which is ordinary Python
with the `gh` call injected. It checks that the reader and the writer of the
count line cannot drift apart. And it checks the workflow's shape: that it never
became a check a pull request waits on, that it opens a pull request rather than
committing to main, and that it says out loud which of its outcomes it took.

It cannot check that the job runs. Only a real run of the macOS workflow can,
and the record's own `measured_from` is what shows it did.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tests.mac_build_setup import uncommented
from tools.record_suite_count import (
    NoRunFound, NothingRanTheSuite, count_in_log, newest_counted_run,
    newest_green_swift_run, worth_proposing)
from tools.suite_counts import FLOOR_TOLERANCE


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ".github/workflows/record-suite-count.yml"


def workflow_text() -> str:
    path = REPO_ROOT / WORKFLOW
    assert path.exists(), (
        f"{WORKFLOW} does not exist, so nothing re-records the count and the "
        f"floor goes slack again the moment the suite grows")
    return path.read_text(encoding="utf-8")


def _gh(reply: str, code: int = 0):
    asked: list[list[str]] = []

    def run(args: list[str]) -> tuple[int, str]:
        asked.append(args)
        return code, reply

    run.asked = asked  # type: ignore[attr-defined]
    return run


RUNS = json.dumps([
    {"databaseId": 33830577621, "headSha": "21e635e0e50c", "conclusion": "success",
     "createdAt": "2026-09-04T02:36:00Z"},
])


# ── which run gets recorded ──────────────────────────────────────────────────

def test_it_records_from_the_newest_green_run_of_the_swift_suite() -> None:
    gh = _gh(RUNS)

    assert newest_green_swift_run(run=gh) == ("33830577621", "21e635e0e50c")

    asked = " ".join(gh.asked[0])
    assert "swift.yml" in asked, "it asked about some other workflow"
    assert "success" in asked, (
        "it did not scope the search to runs that went green, so it would "
        "record the count from a run that may have stopped early, and a floor "
        "pinned to how far a broken run got is refused by nothing forever "
        "after (L182)")


def test_gh_failing_is_not_the_same_as_there_being_no_run() -> None:
    # A job that reported "nothing to record" on a broken token would say it
    # every day and read as a record that is up to date (L11, L98).
    with pytest.raises(NoRunFound) as refusal:
        newest_green_swift_run(run=_gh("HTTP 401", code=1))

    assert "401" in str(refusal.value)


def test_an_empty_list_of_runs_says_so_in_its_own_words() -> None:
    with pytest.raises(NoRunFound) as refusal:
        newest_green_swift_run(run=_gh("[]"))

    assert "401" not in str(refusal.value)
    assert "swift.yml" in str(refusal.value)


def test_it_walks_past_a_run_that_skipped_rather_than_refusing() -> None:
    """The newest green run is usually a push to main whose swift-unit SKIPPED,
    because the tree had already been checked by the pull request that produced
    it. A search of one run would refuse on almost every trigger, and a recorder
    that never records is one nobody can tell from a recorder that stopped
    running (L98, L557)."""
    two = json.dumps([
        {"databaseId": 2, "headSha": "bbb", "conclusion": "success",
         "createdAt": "2026-09-04T03:00:00Z"},
        {"databaseId": 1, "headSha": "aaa", "conclusion": "success",
         "createdAt": "2026-09-04T02:36:00Z"},
    ])

    def gh(args: list[str]) -> tuple[int, str]:
        if args[:3] == ["gh", "run", "list"]:
            return 0, two
        if "2" in args:
            return 0, "swift-unit\tSay whether ... already checked\tskipping\n"
        return 0, LOG

    assert newest_counted_run(run=gh) == ("1", "aaa", 2965)


def test_a_day_of_runs_with_no_count_is_its_own_refusal() -> None:
    # "The newest run skipped" and "nothing in a day of runs ran the suite" are
    # different problems, and only the second means something is wrong (L11).
    def gh(args: list[str]) -> tuple[int, str]:
        if args[:3] == ["gh", "run", "list"]:
            return 0, RUNS
        return 0, "nothing here\n"

    with pytest.raises(NoRunFound) as refusal:
        newest_counted_run(run=gh)

    assert "none of the 1" in str(refusal.value)


# ── reading the count out of the run ─────────────────────────────────────────

LOG = (
    "swift-unit\tRun the Swift suite\t2026-09-04T02:40:01Z Test Suite passed\n"
    "swift-unit\tRun the Swift suite\t2026-09-04T02:40:02Z Swift: 2965 tests\n"
)


def test_the_count_is_read_out_of_the_runs_own_log() -> None:
    assert count_in_log(LOG) == 2965


def test_a_log_with_no_count_is_refused_rather_than_read_as_zero() -> None:
    # swift-unit SKIPS its work on a push whose tree a green pull request has
    # already checked, and a skipped job's log carries no count at all. Reading
    # that as a suite holding nothing would set a floor every run on earth
    # clears (L98).
    with pytest.raises(NoRunFound) as refusal:
        count_in_log("swift-unit\tSay whether a green pull request already "
                     "checked this tree\tskipping\n")

    assert "no" in str(refusal.value).lower()


def test_two_counts_that_disagree_are_refused_rather_than_averaged() -> None:
    # A failure message quotes its subject, so a line naming a count is not
    # necessarily the count (L156). One reading or none.
    with pytest.raises(NoRunFound):
        count_in_log(LOG + "swift-unit\tstep\tSwift: 1300 tests\n")


def test_a_count_of_zero_is_refused() -> None:
    with pytest.raises(NoRunFound):
        count_in_log("swift-unit\tstep\tSwift: 0 tests\n")


def test_the_reader_and_the_writer_of_that_line_cannot_drift_apart() -> None:
    # The line is printed by tools/suite_counts.py and parsed here. Two
    # spellings of one format is how they come apart, and the failure is silent:
    # a reader that matches nothing reports a run with no count (L41, L100).
    source = (REPO_ROOT / "tools/suite_counts.py").read_text(encoding="utf-8")

    assert 'print(f"{label}: {counted} tests")' in source, (
        "tools/suite_counts.py no longer prints the count in the shape this "
        "file reads, so the recorder would find no count in every log and "
        "report a suite that never ran")


def test_a_recorder_that_cannot_LOOK_is_told_apart_from_one_with_nothing_to_read() -> None:
    """Only one of the two is somebody's problem right now, and the workflow
    goes red on one and reports the other (L11, L13, L36).

    A broken token means the recorder cannot see, so nothing here can say
    whether the floor has gone slack. A stretch of pushes whose swift-unit all
    skipped is the suite working exactly as designed."""
    def blind(args: list[str]) -> tuple[int, str]:
        return 1, "HTTP 401"

    def quiet(args: list[str]) -> tuple[int, str]:
        if args[:3] == ["gh", "run", "list"]:
            return 0, RUNS
        return 0, "skipping\n"

    with pytest.raises(NoRunFound) as cannot_look:
        newest_counted_run(run=blind)
    assert not isinstance(cannot_look.value, NothingRanTheSuite), (
        "a recorder that could not reach GitHub reports as a quiet day, so a "
        "broken token would say 'nothing to record' every time and read as a "
        "record that is up to date")

    with pytest.raises(NothingRanTheSuite):
        newest_counted_run(run=quiet)


def test_the_softer_refusal_is_still_caught_by_every_existing_handler() -> None:
    # A subclass rather than a sibling, so splitting them cannot turn one of
    # them into a refusal that escapes its callers.
    assert issubclass(NothingRanTheSuite, NoRunFound)


def test_the_workflow_goes_red_only_on_the_refusal_that_means_something() -> None:
    text = uncommented(workflow_text())

    assert "continue-on-error" not in text, (
        "the recorder's refusals are swallowed into a summary line, so a "
        "broken token produces a green workflow saying nothing happened, which "
        "is exactly what a working recorder with nothing to do also produces "
        "(L13, L98)")
    assert "|| [ $? -eq 3 ]" in text, (
        "nothing lets the quiet outcome through, so an ordinary stretch of "
        "pushes whose swift-unit skipped turns this red every time and teaches "
        "everybody to ignore it (L36)")


# ── whether it is worth proposing ────────────────────────────────────────────

def test_a_record_that_still_holds_the_floor_up_proposes_nothing() -> None:
    # A pull request per merge that adds a test is noise, and noise is how a
    # real one stops being read (L36). The floor is a minimum with a stated
    # tolerance, so a record inside that tolerance is doing its job.
    assert worth_proposing(measured=2965, recorded=2960) is False


def test_a_record_the_suite_has_grown_away_from_is_proposed() -> None:
    assert worth_proposing(measured=2965, recorded=2599) is True


def test_the_line_it_is_judged_against_is_the_floors_own_tolerance() -> None:
    # Derived from FLOOR_TOLERANCE rather than a second number written beside
    # it, or the two drift and the proposal fires for a record the floor is
    # perfectly happy with (L41, L70).
    measured = 10_000
    edge = int(measured * (1 - FLOOR_TOLERANCE))

    assert worth_proposing(measured=measured, recorded=edge) is False
    assert worth_proposing(measured=measured, recorded=edge - 1) is True


def test_a_count_below_the_record_is_never_proposed_automatically() -> None:
    # Lowering the floor is what a deliberate deletion needs, and it is the one
    # direction nothing downstream can report as wrong: a floor that is too LOW
    # only ever refuses runs beneath it, so every later run clears it and the
    # check goes on reading as protection (L182). That stays a person's act.
    assert worth_proposing(measured=2000, recorded=2965) is False


# ── the workflow's shape ─────────────────────────────────────────────────────

def test_the_recorder_never_became_a_check_a_pull_request_waits_on() -> None:
    # tools/wait_for_checks.py derives the bar from the workflows that trigger
    # on pull requests, and a new check name can only go green once its recorded
    # reply already holds it, so adding one costs a knowingly red merge (L48).
    text = uncommented(workflow_text())

    assert "pull_request" not in text, (
        "the recorder triggers on pull requests, so it is now a check every "
        "merge waits for")


def test_it_follows_the_swift_workflow_by_the_name_that_workflow_carries() -> None:
    # `workflow_run` offers only a name, and a name that matches nothing fires
    # never, which looks exactly like a workflow with nothing to do (L100, L98).
    # So the name is read out of swift.yml rather than trusted from the copy
    # here.
    named = [line.split(":", 1)[1].strip()
             for line in uncommented((REPO_ROOT / ".github/workflows/swift.yml")
                              .read_text(encoding="utf-8")).splitlines()
             if line.startswith("name:")]
    assert named, "swift.yml has no name for anything to follow"

    assert f'["{named[0]}"]' in uncommented(workflow_text()), (
        f"the recorder follows a workflow called something other than "
        f"{named[0]!r}, so it fires never and reads as having nothing to do")


def test_it_opens_a_pull_request_rather_than_pushing_to_main() -> None:
    text = uncommented(workflow_text())

    assert "gh pr create" in text
    assert "git push" in text
    assert "--force-with-lease" in text, (
        "a re-run of the same day would be refused by a plain push, which "
        "reads as the recorder failing rather than as it having already run")


def test_it_carries_a_deadline() -> None:
    # A job without one cannot fail, it can only hang (L110, L313).
    assert "timeout-minutes:" in uncommented(workflow_text())


def test_every_outcome_it_can_reach_is_said_apart_in_the_summary() -> None:
    # Nothing to record, a record that already holds, a record proposed, and a
    # record that moved with no way to propose it are different events, and only
    # some need anybody to do anything (L11, L98).
    text = uncommented(workflow_text())

    assert "GITHUB_STEP_SUMMARY" in text
    assert "RECORD_UPDATE_TOKEN" in text, (
        "a pull request opened with the default token starts no workflow runs, "
        "so it would carry no checks and could never be merged. The job has to "
        "say when it could not open one rather than looking like it did")
