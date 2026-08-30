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
import subprocess
import sys
from datetime import date
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.check_guards import EXECUTED  # noqa: E402
from tools.suite_counts import RECORDED_COUNT  # noqa: E402


class RecordError(Exception):
    """The transcript does not support writing a floor from it."""


def count_from_transcript(log: str) -> int:
    """How many tests a FINISHED, GREEN Swift run executed.

    Two refusals, kept apart because they send you to different places (L11):
    a transcript with no total never got as far as reporting, and a transcript
    with failures reported a run that may have stopped early.
    """
    totals = EXECUTED.findall(log)
    if not totals:
        raise RecordError(
            "the transcript never reported an executed-tests total, so the "
            "build broke before any test ran or the log was written somewhere "
            "else. Nothing can be recorded from it")

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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path,
                        help="a transcript of a green Swift run")
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
    args = parser.parse_args(argv)

    try:
        transcript = args.log.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        # A missing FILE, never an empty run. A transcript that went somewhere
        # else must not be recorded as a suite that holds nothing (L11, L100).
        print(f"could not read {args.log}: {error}", file=sys.stderr)
        return 1

    try:
        counted = count_from_transcript(transcript)
    except RecordError as refusal:
        # Nothing is written on this path, deliberately. Writing a partial or
        # placeholder record here is how the floor would come to be pinned to a
        # run that did not finish.
        print(f"not recorded: {refusal}", file=sys.stderr)
        return 1

    args.record.write_text(
        json.dumps({
            "count": counted,
            "measured_on": date.today().isoformat(),
            "measured_at_commit": args.commit or _commit(),
            "measured_from": f"Executed {counted} tests, with 0 failures, "
                             f"read from {args.log.name}",
            "re_measure_with": "venv/bin/python tools/record_suite_count.py",
        }, indent=2) + "\n",
        encoding="utf-8")

    print(f"recorded {counted} Swift tests in {args.record}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
