#!/usr/bin/env python3
"""Write down how many tests the Swift suite holds, from a run that finished (#1017).

`tools/suite_counts.py` refuses a Swift leg that executed far fewer tests than
the suite is known to hold. That floor is derived from a number, and this is the
only thing that writes it.

    venv/bin/python tools/record_suite_count.py <swift-run.log>

Re-run it after deliberately deleting tests, which is the one legitimate way a
run lands under the floor. Adding tests needs nothing: the floor is a minimum,
and a suite above it stays above it.

## Why it will not write from a red run

A failing run may not have finished. Recording its count pins the floor to
however far it got, and a floor that is too LOW is the one kind of wrong nothing
downstream ever reports: it only ever refuses runs beneath it, so every later
run clears it and the check goes on reading as protection (L182).
`tools/record_test_durations.py` refuses a red run for exactly this reason.

## Why the record carries a commit and a date

The issue that asked for this floor recorded the suite at 2,546 tests. It was
2,599 by the time the work started, and nothing anywhere reported the drift,
because a number written into prose reads as a current fact for as long as it
sits there (L316, and #1033 is the general form). The record therefore says
where its number came from and how to take the reading again, so a reader can
re-measure rather than believe.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.check_guards import EXECUTED  # noqa: E402
from tools.suite_counts import (  # noqa: E402
    FLOOR_TOLERANCE, RECORDED_COUNT, SuiteCountError, swift_tests_run)


class RecordError(Exception):
    """The transcript does not support writing a floor from it."""


class NoRunFound(Exception):
    """CI could not be ASKED, so nothing is known either way (#1261).

    Its own type rather than an empty answer, because the caller ACTS on the
    answer: a job reporting "nothing to record" on a broken token would say it
    every day and read as a record that is up to date (L11, L98).
    """


class NothingRanTheSuite(NoRunFound):
    """CI answered, and none of the runs it named carries a count.

    Kept apart from its parent because only one of the two is somebody's
    problem right now. A broken token or a refused API call means the recorder
    cannot see, and that is an outage of the recorder itself. A run of pushes
    whose swift-unit all skipped is the suite working exactly as designed, and
    a workflow that went red for it every time would be the noise that stops a
    real one being read (L11, L36).

    A subclass rather than a sibling, so every existing `except NoRunFound`
    still catches it and this cannot become a refusal that escapes.
    """


#: Which workflow the reading comes from, and which job inside it.
#:
#: Any successful run of it, whatever triggered it. A pull request run measures
#: the same tree the merge lands, because `wait_for_checks.py --merge` refuses a
#: head that does not contain main and squashes it, which produces the head's
#: tree byte for byte. Scoping to `push` instead would find almost nothing:
#: swift-unit SKIPS its work on a push whose tree a green pull request already
#: checked, and a skipped job leaves no count.
SUITE_WORKFLOW = "swift.yml"

#: The branch the recorded floor is a claim ABOUT (#1398).
#:
#: Without it the query took the newest successful Swift run from anywhere, so
#: a pull request's run supplied main's floor. Measured 2026-09-05: three
#: proposals in one day recorded it at 9fb5981, ecd2210 and c0fd193, every one
#: a pull request head. The count agreed each time by luck, those branches
#: having added only Python tests, and a branch that REMOVES Swift tests would
#: have proposed a smaller floor, recalibrating the guard downwards by the very
#: change it exists to notice (L182, L237).
SUITE_BRANCH = "main"
SUITE_JOB = "swift-unit"

#: The line `tools/suite_counts.py` prints, read back.
#:
#: Not anchored to the start of a line: a runner log prefixes every line with
#: the job name, the step name and a timestamp.
COUNTED = re.compile(r"Swift: (\d+) tests")


def _gh(args: list[str]) -> tuple[int, str]:
    try:
        done = subprocess.run(args, capture_output=True, text=True)
    except FileNotFoundError as missing:
        raise NoRunFound(
            "the gh CLI is not on PATH, so no run could be looked up"
        ) from missing
    return done.returncode, done.stdout + done.stderr


#: How far back to look for a run that actually ran the suite.
#:
#: More than one, because the NEWEST green run is usually a push to main whose
#: swift-unit skipped: the tree had already been checked by the pull request
#: that produced it. Those leave no count, so a search of one run would refuse
#: on almost every trigger and a recorder that never records is one nobody can
#: tell from a recorder that stopped running (L98, L557).
#:
#: Ten, which is about a day of merges here and cheap: each candidate past the
#: first costs one log read, and the walk stops at the first that carries a
#: count.
RUNS_TO_LOOK_BACK = 10


def green_swift_runs(run=None, limit: int = RUNS_TO_LOOK_BACK
                     ) -> list[tuple[str, str]]:
    """The newest successful runs of the Swift suite, newest first.

    Green only. A run that failed may have stopped early, and a floor pinned to
    how far a broken run got is the one kind of wrong nothing downstream ever
    reports: it only ever refuses runs beneath it, so every later run clears it
    and the check goes on reading as protection (L182).
    """
    if run is None:
        run = _gh
    code, output = run([
        "gh", "run", "list",
        "--workflow", SUITE_WORKFLOW,
        "--branch", SUITE_BRANCH,
        "--status", "success",
        "--limit", str(limit),
        "--json", "databaseId,headSha,conclusion,createdAt",
    ])
    if code != 0:
        raise NoRunFound(
            f"gh could not list the Swift suite's runs (exit {code}): "
            f"{output.strip()[:200]}. That is not the same as there being none")
    try:
        runs = json.loads(output)
    except ValueError as error:
        raise NoRunFound(
            f"gh printed something that is not JSON: {output.strip()[:200]}"
        ) from error
    if not runs:
        raise NoRunFound(
            f"no successful run of {SUITE_WORKFLOW} was found, so there is "
            f"nothing to record from. The suite may have been failing")
    return [(str(r["databaseId"]), str(r["headSha"])) for r in runs]


def newest_green_swift_run(run=None) -> tuple[str, str]:
    """The newest successful run of the Swift suite, as (run id, head commit)."""
    if run is None:
        run = _gh
    return green_swift_runs(run=run, limit=1)[0]


def newest_counted_run(run=None) -> tuple[str, str, int]:
    """The newest green run that actually ran the suite, and what it counted.

    Walks back rather than taking the first, because a push to main whose tree
    a green pull request already checked SKIPS swift-unit and leaves no count.
    That is the ordinary state of the newest run, not an edge case.

    Every candidate refusing is its OWN refusal, naming how many were looked at,
    rather than the last one's reason: "the newest run skipped" and "nothing in
    a day of runs ran the suite" are different problems (L11).
    """
    if run is None:
        run = _gh
    candidates = green_swift_runs(run=run)
    reasons: list[str] = []
    for run_id, head in candidates:
        try:
            return run_id, head, count_in_log(log_of(run_id, run=run))
        except NoRunFound as refusal:
            reasons.append(f"{run_id}: {refusal}")
    raise NothingRanTheSuite(
        f"none of the {len(candidates)} newest green runs of {SUITE_WORKFLOW} "
        f"carries a Swift test count, so there is nothing to read. "
        f"{reasons[0] if reasons else ''}")


def count_in_log(log: str) -> int:
    """How many tests a run's log says the Swift leg executed.

    Three refusals, kept apart because they send you to different places (L11).

    NO count at all is the common one and it is not an empty suite: swift-unit
    skips its work on a push whose tree a green pull request already checked,
    and a skipped job's log carries nothing. Reading that as a suite holding
    nothing would set a floor every run on earth clears (L98, L100).

    Two DIFFERENT counts is refused rather than averaged or taken last. A
    failure message quotes its subject, so a line naming a count is not
    necessarily the count (L156), and a record assembled from two readings is a
    number nobody measured.

    Zero is refused for the reason `count_from_transcript` refuses it: a
    selection that matched nothing rather than a suite that holds nothing.
    """
    found = {int(n) for n in COUNTED.findall(log)}
    if not found:
        raise NothingRanTheSuite(
            "that run's log carries no Swift test count. The job most likely "
            "SKIPPED, which swift-unit does on a push whose tree a green pull "
            "request already checked, and a skipped job is not a suite that "
            "holds nothing")
    if len(found) > 1:
        raise NoRunFound(
            f"that run's log carries {len(found)} different Swift test counts "
            f"({', '.join(str(n) for n in sorted(found))}), so no single "
            f"reading can be taken from it. Nothing was written")
    counted = found.pop()
    if counted == 0:
        raise NoRunFound(
            "that run executed 0 tests, which is a selection that matched "
            "nothing rather than a suite that holds nothing. Recording it "
            "would set a floor every run on earth clears")
    return counted


def log_of(run_id: str, run=None) -> str:
    """One run's log for the Swift job, or a refusal naming why not."""
    if run is None:
        run = _gh
    code, output = run(["gh", "run", "view", str(run_id), "--log",
                        "--job", SUITE_JOB])
    if code != 0:
        # `--job` takes an id rather than a name on some gh versions, so fall
        # back to the whole run's log and let `count_in_log` judge it. Named
        # here rather than silently, because a fallback nobody can see is how
        # a reading comes from somewhere other than where it was asked for.
        code, output = run(["gh", "run", "view", str(run_id), "--log"])
    if code != 0:
        raise NoRunFound(
            f"gh could not read run {run_id}'s log (exit {code}): "
            f"{output.strip()[:200]}")
    return output


def worth_proposing(measured: int, recorded: int) -> bool:
    """Whether the record has drifted far enough from the suite to re-record.

    Judged against the floor's OWN tolerance rather than a second number
    written beside it, or the two drift and the proposal fires for a record the
    floor is perfectly happy with (L41, L70). The floor is
    `recorded * (1 - FLOOR_TOLERANCE)`, so a record at or above
    `measured * (1 - FLOOR_TOLERANCE)` is still holding the line it was
    designed to hold, and a pull request about it is noise (L36).

    Never downward. Lowering the floor is what a deliberate deletion needs, and
    it is the one direction nothing downstream can report as wrong, so it stays
    a person's act (L182). A count below the record leaves the floor too high,
    which fails loudly and names the tool that re-records.
    """
    return recorded < int(measured * (1 - FLOOR_TOLERANCE))


def count_from_transcript(log: str) -> int:
    """How many tests a FINISHED, GREEN Swift run executed.

    Two refusals, kept apart because they send you to different places (L11):
    a transcript with no total never got as far as reporting, and a transcript
    with failures reported a run that may have stopped early.
    """
    totals = EXECUTED.findall(log)
    if not totals:
        raise RecordError(
            "the transcript never reported an executed-tests total. Either the "
            "build broke before any test ran, the log was written somewhere "
            "else, or the run was PARALLEL: since #992 the Swift suite runs "
            "with -parallel-testing-enabled and xcodebuild prints no total at "
            "all in that mode. Re-record from the run's result bundle instead: "
            "record_suite_count.py --result-bundle <path.xcresult>")

    executed, failures = int(totals[-1][0]), int(totals[-1][1])

    if failures:
        raise RecordError(
            f"the run reported {failures} failures, so it is not a measurement "
            f"of what the suite holds: a run that failed may have stopped "
            f"early, and a floor recorded too LOW is refused by nothing "
            f"forever after (L182). Fix the suite, then record from a green run")

    if executed == 0:
        raise RecordError(
            "the run executed 0 tests, which is a selection that matched "
            "nothing rather than a suite that holds nothing. Recording it "
            "would set a floor every run on earth clears")

    return executed


def count_from_result_bundle(bundle, read=None) -> int:
    """How many tests a green PARALLEL run executed, from its result bundle.

    The transcript reader above cannot serve a parallel run, and counting the
    per-test lines instead is not an option: six workers write them to one
    stdout and they interleave, undercounting by 1 in 2,614 the first time it
    was measured. The bundle is written through the test framework rather than
    through a shared pipe.

    `swift_tests_run` already refuses an absent bundle, an unreadable one, a
    total that is not a count and a total of zero, so those are not restated
    here: two readings of one number is how they drift (L41). What IS restated
    is the refusal that belongs to this tool rather than to that one, that a run
    which was not green may have stopped early and must not set the floor
    (L182).
    """
    reader = read if read is not None else (
        lambda path: swift_tests_run("", bundle=path))
    try:
        return reader(bundle)
    except SuiteCountError as refusal:
        raise RecordError(
            f"nothing can be recorded from that result bundle: {refusal}"
        ) from refusal


def _commit() -> str:
    """The commit the reading was taken at, so it can be taken again.

    An unknown commit is recorded AS unknown rather than as an empty string: a
    blank field reads as a record nobody filled in, and the two need telling
    apart by anyone deciding whether to trust the number (L11).
    """
    try:
        found = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT,
            capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return "unknown, git could not be asked"
    return found.stdout.strip()


def _record_from_newest_run(record: Path, commit: str | None) -> int:
    """Record from CI, and only when the floor has actually gone slack (#1261).

    Three outcomes, exit codes apart, because the caller acts differently on
    each (L11): 0 looked and either wrote or had no reason to, 1 could not look
    at all, 3 looked and nothing had run the suite. Only 1 means something is
    wrong with the recorder itself, and only 1 is worth going red for.

    Every one of them PRINTS. A recorder that says nothing whether it looked or
    not is one nobody can tell from a recorder that stopped running (L98).
    """
    try:
        run_id, head, measured = newest_counted_run()
    except NothingRanTheSuite as nothing:
        # Exit 3, not 1. CI answered and every run it named had skipped the
        # suite, which is swift-unit working as designed on a push whose tree a
        # pull request already checked. The caller reports this rather than
        # failing on it, or the workflow goes red on an ordinary quiet stretch
        # and teaches everybody to ignore it (L36).
        print(f"nothing to record: {nothing}")
        return 3
    except NoRunFound as refusal:
        # Exit 1. CI could not be ASKED, so the recorder is blind and nothing
        # here can say whether the floor has gone slack. That is the recorder's
        # own outage and it has to be loud (L13, L98).
        print(f"not recorded: {refusal}", file=sys.stderr)
        return 1

    try:
        recorded = int(json.loads(record.read_text(encoding="utf-8"))["count"])
    except (OSError, ValueError, KeyError, TypeError):
        # A record that cannot be read is not a record the suite has grown away
        # from, and the two need telling apart (L11). Writing is right here:
        # there is no floor at all until something does.
        recorded = 0

    if not worth_proposing(measured=measured, recorded=recorded):
        print(f"nothing to record: run {run_id} executed {measured} tests and "
              f"the record holds {recorded}, which still derives a floor within "
              f"{FLOOR_TOLERANCE:.0%} of what the suite runs")
        return 0

    _write(record, counted=measured, commit=commit or head,
           source=f"run {run_id} of {SUITE_WORKFLOW}, job {SUITE_JOB}")
    print(f"recorded {measured} Swift tests in {record}, up from {recorded}")
    return 0


def _write(record: Path, counted: int, commit: str, source: str) -> None:
    """The record itself, written in ONE place.

    Both paths into this tool land here, so the fields a reader trusts cannot
    come to say different things depending on which one wrote them (L41).
    """
    record.write_text(
        json.dumps({
            "count": counted,
            "measured_on": date.today().isoformat(),
            "measured_at_commit": commit,
            "measured_from": f"{counted} tests, no failures, read from {source}",
            "re_measure_with": "venv/bin/python tools/record_suite_count.py "
                               "--from-newest-run",
        }, indent=2) + "\n",
        encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, nargs="?",
                        help="a transcript of a green SERIAL Swift run")
    parser.add_argument("--result-bundle", type=Path, default=None,
                        help="a green run's .xcresult, which is the only source "
                             "a PARALLEL run leaves (#992)")
    parser.add_argument("--record", type=Path, default=RECORDED_COUNT,
                        help="where to write it (defaults to the committed record)")
    # Needed whenever the transcript came from somewhere other than this
    # checkout, which is the normal case for a runner's log. Without it the
    # record stamps the local HEAD onto a reading taken at a different commit,
    # and a provenance field that is confidently wrong is worse than none: it is
    # exactly the field a reader trusts instead of re-measuring (L249, L176).
    parser.add_argument("--commit", default=None,
                        help="the commit the run happened at, when the "
                             "transcript did not come from this checkout")
    parser.add_argument("--from-newest-run", action="store_true",
                        help="read the count off the newest green run of the "
                             "Swift suite in CI, and write it only when the "
                             "record has gone slack (#1261)")
    args = parser.parse_args(argv)

    if args.from_newest_run:
        if args.log is not None or args.result_bundle is not None:
            print("--from-newest-run names its own source, so it takes neither "
                  "a transcript nor --result-bundle", file=sys.stderr)
            return 2
        return _record_from_newest_run(args.record, args.commit)

    # Exactly one source, named by the caller. Neither is guessed at and
    # neither falls back to the other: a parallel transcript is PRESENT and
    # quietly carries no total, so a fallback written for an absent source would
    # land straight on it (L214).
    if (args.log is None) == (args.result_bundle is None):
        print("give exactly one of a transcript path (a serial run) or "
              "--result-bundle (a parallel one). Since #992 the suite runs in "
              "parallel and prints no executed-tests total, so a run from CI or "
              "from `make test-swift` is the second kind.", file=sys.stderr)
        return 2

    if args.result_bundle is not None:
        source = args.result_bundle.name
        try:
            counted = count_from_result_bundle(args.result_bundle)
        except RecordError as refusal:
            print(f"not recorded: {refusal}", file=sys.stderr)
            return 1
    else:
        source = args.log.name
        try:
            transcript = args.log.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            # A missing FILE, never an empty run. A transcript that went
            # somewhere else must not be recorded as a suite that holds nothing
            # (L11, L100).
            print(f"could not read {args.log}: {error}", file=sys.stderr)
            return 1

        try:
            counted = count_from_transcript(transcript)
        except RecordError as refusal:
            # Nothing is written on this path, deliberately. Writing a partial
            # or placeholder record here is how the floor would come to be
            # pinned to a run that did not finish.
            print(f"not recorded: {refusal}", file=sys.stderr)
            return 1

    _write(args.record, counted=counted, commit=args.commit or _commit(),
           source=source)

    print(f"recorded {counted} Swift tests in {args.record}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
