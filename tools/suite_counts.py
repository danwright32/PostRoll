#!/usr/bin/env python3
"""How many tests a suite leg actually ran, read from its own transcript (#932).

`make test` ran the Swift suite alone. Nothing in the name said so, it printed
no summary separating the two halves, and a green run therefore read as the
whole suite passing while roughly 4000 Python tests had never been started. It
misled twice.

Splitting the target in two fixes the name. This fixes the reporting, which is
the half that keeps it honest: a run that executed NOTHING exits green from
both runners, so the count is the only thing that tells a full run from a half
one (L98). Measured on 2026-08-28: `pytest -k <no match>` prints "no tests ran"
and exits 0, and xcodebuild reports TEST SUCCEEDED for a `-only-testing` spec
that matched nothing, which is the same defect #644 found in the review sheet.

## Why two refusals rather than one

An ABSENT total and a total of ZERO are different failures and get different
messages. Absent means the runner never got as far as reporting: a build that
did not compile, a log written somewhere else, an import that blew up. Zero
means it ran and found nothing to do, which is a selection problem. Telling
somebody to check their test spec when the build is broken sends the diagnosis
somewhere unrelated (L11).

## Why the Swift half is not written here

`tools.check_guards` already reads this exact line for the guard sweep, and
already decided that the LAST match in a transcript is the grand total rather
than the last class's. Two readings of one line is how they drift (L41).

## And why the Swift half has a second source since #992

Running the suite in parallel removes that line from the transcript entirely:
zero occurrences of `Executed N tests` in a whole 2,940 line parallel run,
measured on 2026-08-30. The per-test lines that remain are written to one stdout
by six worker processes and interleave, so one was corrupted mid-write and a
count taken from them was short by exactly 1 in 2,614 on the first run anybody
tried, which is well inside the floor's 51 test tolerance.

So a parallel run is counted from its RESULT BUNDLE, which the workers write
through the test framework rather than through a shared pipe, and the transcript
reader stays exactly as it was for every serial caller, `check_guards` above all.
Which source is used is decided by the caller passing a bundle, never guessed
at, and there is deliberately no fallback between them: see `swift_tests_run`.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.check_guards import EXECUTED  # noqa: E402

#: What the Swift suite was last MEASURED at, beside the other measured records
#: (`test_file_durations.json` is written by a tool and read by a guard the same
#: way). Written by `tools/record_suite_count.py` from a green run, never by
#: hand: a number typed in is a number nobody measured, and it reads as a
#: current fact for as long as it sits there (L32, L316).
RECORDED_COUNT = REPO_ROOT / "tests" / "fixtures" / "swift_suite_count.json"


class SuiteCountError(Exception):
    """The transcript does not support a claim that the leg ran."""


def recorded_swift_count(path: Path | None = None) -> int:
    """How many Swift tests the suite was last measured at.

    Three refusals rather than one, because an ABSENT file, an unreadable one
    and a present file that does not answer are three different things to go and
    fix, and a single message would send two of the three somewhere unrelated
    (L11).

    No default standing for absent anywhere in here. `.get("count", 0)` would
    turn a renamed key into a floor of zero, which every run on earth clears, so
    the guard would keep reading as a safeguard while refusing nobody (L138).
    """
    record = RECORDED_COUNT if path is None else path

    try:
        text = record.read_text(encoding="utf-8")
    except OSError as error:
        raise SuiteCountError(
            f"could not read the recorded Swift test count at {record}: "
            f"{error}. Without it there is no floor and nothing held this run "
            f"to one. Re-record it with tools/record_suite_count.py") from error

    try:
        held = json.loads(text)
    except json.JSONDecodeError as error:
        raise SuiteCountError(
            f"the recorded Swift test count at {record} is not readable JSON: "
            f"{error}. That is a corrupt record, not a short suite") from error

    if not isinstance(held, dict) or "count" not in held:
        raise SuiteCountError(
            f"the record at {record} has no `count`, so it cannot say what the "
            f"suite holds. A record that does not answer the question is not a "
            f"floor of zero, it is no floor at all")

    return int(held["count"])


#: The tail of a pytest summary line: `in 3.93s`, or `in 130.02s (0:02:10)`
#: once a run passes a minute. Anchored to the end of the line so a sentence
#: mentioning a duration in the middle of a test's own output cannot answer it.
_PYTEST_TAIL = re.compile(
    r"\bin \d+(?:\.\d+)?s(?: \(\d+:\d{2}:\d{2}\))?$")

#: The outcomes that mean a test RAN.
#:
#: A skip counts. It is a test that was collected, reached and reported on, and
#: this number exists to say the suite was reached rather than to say everything
#: passed: `make test` fails on the runner's own exit code.
#:
#: `deselected` is deliberately absent, and it is the one that matters: a
#: deselected test did not run, so counting it would let the fast subset's
#: number stand in for the full suite's, which is this issue in miniature.
#: `warnings` and `errors` in the pytest sense of collection errors are handled
#: below: an error IS a test that was reached.
_RAN = ("passed", "failed", "error", "errors", "skipped", "xfailed", "xpassed")

_OUTCOME = re.compile(r"\b(\d+) (" + "|".join(_RAN) + r")\b")


#: How the result bundle is read. Named here so a test can pass its own reader
#: and never shell out, and so the one place that knows the command is the one
#: place that has to change when Xcode moves it again.
XCRESULTTOOL = ("xcrun", "xcresulttool", "get", "test-results", "summary")


def count_from_summary(payload: object) -> int:
    """The executed-test total out of one `xcresulttool` summary.

    Pure, so the refusals below can be tested without a bundle on disk. Every
    shape that is not a whole positive count is refused rather than coerced: a
    value parsed from another tool's output must not feed a comparison directly
    (L50), and an absent field is a broken read rather than a measurement of
    zero (L11).
    """
    if not isinstance(payload, dict):
        raise SuiteCountError(
            f"the result bundle summary was {type(payload).__name__}, not an "
            "object, so nothing here can say how many tests ran")
    if "totalTestCount" not in payload:
        raise SuiteCountError(
            "the result bundle summary carries no totalTestCount, so the "
            "bundle was written by something this cannot read. That is a "
            "failure of this reader, not a suite that ran no tests")
    total = payload["totalTestCount"]
    if isinstance(total, bool) or not isinstance(total, int) or total < 0:
        raise SuiteCountError(
            f"the result bundle reported totalTestCount={total!r}, which is "
            "not a count of anything")
    if total == 0:
        raise SuiteCountError(
            "the result bundle reports 0 tests. A test spec that matches "
            "nothing still exits green, so this looks exactly like a full run "
            "(L98). Check the scheme and the -only-testing/-skip-testing names")
    return total


def read_bundle_summary(bundle: Path) -> dict:
    """`xcresulttool`'s summary for one bundle, as a dict.

    Every way this can fail raises, because an empty answer read as a real one
    is the single thing the count exists to prevent (L98).
    """
    command = [*XCRESULTTOOL, "--path", str(bundle), "--compact"]
    try:
        done = subprocess.run(command, capture_output=True, text=True,
                              check=False)
    except OSError as error:
        raise SuiteCountError(
            f"could not run xcresulttool: {error}") from error
    if done.returncode != 0:
        raise SuiteCountError(
            f"xcresulttool exited {done.returncode} reading {bundle.name}: "
            f"{(done.stderr.strip() or done.stdout.strip())[:200] or '(silence)'}")
    try:
        return json.loads(done.stdout)
    except json.JSONDecodeError as error:
        raise SuiteCountError(
            f"xcresulttool printed something that is not JSON for "
            f"{bundle.name}: {error}") from error


def swift_tests_run(log: str, bundle: Path | None = None,
                    read_summary=None) -> int:
    """How many tests xcodebuild reported executing.

    From the result bundle when the caller names one, and from the transcript
    otherwise. The caller decides, because it is the caller that knows whether
    it asked for a parallel run.

    There is deliberately NO fallback from the bundle to the transcript. A
    fallback written for a source being ABSENT must not be reached when the
    source is present and broken (L214), and in a parallel run the transcript is
    exactly that: present, and quietly missing the total. Worse, it can carry a
    number from one sub-suite, so falling back would report a short run as a
    full one, which is the defect this whole file exists to prevent.
    """
    if read_summary is None:
        read_summary = read_bundle_summary
    if bundle is not None:
        if not bundle.exists():
            raise SuiteCountError(
                f"the run named {bundle} as its result bundle and there is "
                "nothing there, so it never got as far as writing one. That is "
                "not a suite that ran zero tests")
        return count_from_summary(read_summary(bundle))

    totals = EXECUTED.findall(log)
    if not totals:
        raise SuiteCountError(
            "the Swift leg never reported an executed-tests total, so the "
            "build broke before any test ran or the log was written somewhere "
            "else. That is not a suite that ran zero tests, and the two need "
            "different fixes")

    executed = int(totals[-1][0])
    if executed == 0:
        raise SuiteCountError(
            "the Swift leg executed 0 tests. A test spec that matches nothing "
            "still exits green, so this looks exactly like a full run (L98). "
            "Check the scheme and the -only-testing/-skip-testing names")
    return executed


#: How far below the recorded count a Swift run may land before it is refused.
#:
#: 2% of the suite, which is 51 tests at the 2,599 recorded today. The number is
#: chosen from both directions rather than picked for feeling careful:
#:
#: It has to CATCH a lost worker's share, which is what #992 can produce. The
#: runner has three cores, so one worker is about a third of the suite and every
#: whole class is well above this line.
#:
#: It has to NOT fire on ordinary deletion between re-recordings. A change that
#: removes more than fifty tests at once is a deliberate removal, and the
#: refusal names the tool that re-records, so it costs one command rather than a
#: puzzle.
#:
#: Expressed as a share rather than a count so it tracks the suite instead of
#: going quietly slack as the suite grows (L182).
FLOOR_TOLERANCE = 0.02


def swift_run_meets_floor(executed: int, recorded: int) -> None:
    """Refuse a Swift leg that ran far fewer tests than the suite is known to hold.

    `swift_tests_run` already refuses a total that is ABSENT and one that is
    ZERO. This is the third refusal, and it is the one the other two cannot
    make: a leg that ran 1,300 of 2,599 reports a perfectly well-formed total,
    exits green, and prints TEST SUCCEEDED.

    Separate from `swift_tests_run` on purpose. That function answers what the
    transcript SAYS, and this one answers whether that is enough. Folding the
    floor into the reader would give one function two verdicts, which is how a
    run of nothing came to read as a full suite in the first place (L53).
    """
    if recorded <= 0:
        # Named as a missing RECORD, not as a short run. A recorded count of
        # zero derives a floor of zero, which every run clears, so without this
        # the check reads as an active safeguard while refusing nobody (L98).
        # The remedy is to write the record, which is nothing to do with the
        # suite that just ran perfectly well (L11).
        raise SuiteCountError(
            f"the recorded Swift test count is {recorded}, so there is no "
            f"floor to judge against and this run was not held to one. That is "
            f"a missing record, not a short suite: re-record the count from a "
            f"green run")

    floor = int(recorded * (1 - FLOOR_TOLERANCE))
    if executed < floor:
        raise SuiteCountError(
            f"the Swift leg executed {executed} tests, below the floor of "
            f"{floor} derived from the {recorded} last recorded. A leg that "
            f"loses a worker's share still exits green and still prints TEST "
            f"SUCCEEDED, so this looks exactly like a full run (L98). If tests "
            f"were deliberately removed, re-record the count; otherwise find "
            f"the {recorded - executed} that did not run")


def python_tests_run(log: str, bundle: Path | None = None) -> int:
    """How many tests pytest reported running, from its final summary line.

    `bundle` is accepted and ignored, so both legs answer one call shape and the
    caller does not have to know which leg it is holding (L263). Only the Swift
    leg has a result bundle; pytest's own summary is not written through a
    shared pipe and does not interleave.

    Read from the LAST summary line rather than by scanning the transcript.
    `-ra` prints a short summary section above it and a test's own captured
    output can say anything at all, so a scan would be answered by either
    (L178).
    """
    for line in reversed(log.splitlines()):
        stripped = line.strip().strip("=").strip()
        if not _PYTEST_TAIL.search(stripped):
            continue
        if stripped.startswith("no tests ran"):
            raise SuiteCountError(
                "the Python leg reported: no tests ran. pytest exits 0 when its "
                "selection matches nothing, so this looks exactly like a full "
                "run (L98). Check the paths, the -k expression and the markers")
        counted = _OUTCOME.findall(stripped)
        if not counted:
            continue
        return sum(int(number) for number, _ in counted)

    raise SuiteCountError(
        "the Python leg never reported a summary line, so pytest did not "
        "finish or the log was written somewhere else. That is not a suite "
        "that ran zero tests, and the two need different fixes")


def _swift_floor(executed: int) -> None:
    """Hold a Swift run to the recorded count. Raises, or says nothing."""
    swift_run_meets_floor(executed, recorded_swift_count())


#: What each leg is called when it reports, how to read its transcript, and what
#: holds its count to a floor.
#:
#: The Python leg deliberately carries NO floor, and the reason is that it
#: already has one that works: pytest-xdist reports a crashed worker's tests as
#: FAILURES rather than dropping them, so a Python leg that loses a share goes
#: red on its own exit code. The Swift leg has no such property, which is the
#: whole of #1017. This is an exemption with a written reason rather than an
#: entry nobody thought about (L233).
LEGS = {
    "swift": ("Swift", swift_tests_run, _swift_floor),
    "python": ("Python", python_tests_run, None),
}


def run_leg(leg: str, command: list[str],
            bundle: Path | None = None) -> int:
    """Run one leg, stream its output, and report how many tests it ran.

    The transcript is streamed line by line rather than captured and printed at
    the end. A suite run is two minutes of progress, and holding it back to read
    one number off the bottom would leave the operator watching a blank screen
    with no way to tell a slow run from a wedged one.

    Two verdicts, kept apart. The runner's exit code says whether the suite was
    GREEN. The count says whether it was REACHED. One field answering both is
    how a run of nothing came to read as a full suite in the first place (L53),
    so a refused count fails the leg even on an exit code of 0, and a red runner
    stays red even when the count is fine.
    """
    label, read, floor = LEGS[leg]
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors="replace", bufsize=1)
    except OSError as error:
        # A command that could not START is not a suite that ran no tests. One
        # is a broken invocation and the other a broken selection, and sending
        # somebody to check their test spec because make cannot find xcodebuild
        # is a diagnosis pointing somewhere unrelated (L11).
        print(f"{label}: could not run {' '.join(command)}: {error}",
              file=sys.stderr)
        return 1

    captured: list[str] = []
    assert process.stdout is not None
    for line in process.stdout:
        captured.append(line)
        sys.stdout.write(line)
        sys.stdout.flush()
    status = process.wait()

    try:
        counted = read("".join(captured), bundle)
    except SuiteCountError as refusal:
        print(f"{label}: {refusal}", file=sys.stderr, flush=True)
        return status or 1

    # Printed BEFORE the floor is applied, so the number is on the screen
    # whichever way the verdict goes. A floor that refuses silently leaves an
    # operator unable to tell a suite that grew from one sitting just above the
    # line, and the count is the thing they need in both cases.
    print(f"{label}: {counted} tests", flush=True)

    if floor is not None:
        try:
            floor(counted)
        except SuiteCountError as refusal:
            print(f"{label}: {refusal}", file=sys.stderr, flush=True)
            return status or 1
    return status


USAGE = ("usage: suite_counts.py <swift|python> <logfile>\n"
         "       suite_counts.py run <swift|python> "
         "[--result-bundle <path.xcresult>] -- <command> [args...]")


def cleared_bundle(path: Path) -> Path:
    """Remove a stale result bundle so xcodebuild will write a fresh one.

    xcodebuild REFUSES to run when `-resultBundlePath` already exists, so
    something has to clear it, and the tool that is going to READ it is the one
    that should: a caller clearing a path this then reads from is two places
    spelling one path (L41).

    Refuses anything not named `.xcresult`. This deletes a directory tree, and
    the argument comes from a command line, so a mistyped path must fail rather
    than take whatever is there with it (L5, L9).
    """
    if path.suffix != ".xcresult":
        raise SuiteCountError(
            f"{path} is not named .xcresult, and this removes whatever it is "
            "pointed at, so it refuses rather than guessing")
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
    return path


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[0] == "run" and argv[1] in LEGS:
        rest = list(argv[2:])
        bundle: Path | None = None
        if len(rest) >= 2 and rest[0] == "--result-bundle":
            bundle = Path(rest[1])
            rest = rest[2:]
        if rest and rest[0] == "--":
            if bundle is not None:
                try:
                    cleared_bundle(bundle)
                except SuiteCountError as refusal:
                    print(f"{LEGS[argv[1]][0]}: {refusal}", file=sys.stderr)
                    return 1
            return run_leg(argv[1], rest[1:], bundle)

    if len(argv) != 2 or argv[0] not in LEGS:
        print(USAGE, file=sys.stderr)
        return 2

    label, read, floor = LEGS[argv[0]]
    path = Path(argv[1])
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        # Named as a missing FILE, not as an empty run. A transcript that went
        # somewhere else must not be reported as a suite that ran nothing
        # (L11, L100).
        print(f"{label}: could not read {path}: {error}", file=sys.stderr)
        return 1

    try:
        counted = read(text, None)
    except SuiteCountError as refusal:
        print(f"{label}: {refusal}", file=sys.stderr)
        return 1

    # The same order as `run_leg`, for the same reason: the count is printed
    # whichever way the floor goes. Reading a transcript from a file is how CI
    # judges a run it did not launch, so the two paths must not disagree about
    # what a short run is (L263).
    print(f"{label}: {counted} tests")

    if floor is not None:
        try:
            floor(counted)
        except SuiteCountError as refusal:
            print(f"{label}: {refusal}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
