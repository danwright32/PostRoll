#!/usr/bin/env python3
"""Keep one issue open while the guard sweep is overdue (#1466).

The full sweep runs only when somebody starts it by hand (#1428). Nothing said
when nobody did: no sweep ran from 2026-09-27 while every daily run read green.
Dan's call (2026-10-03) was to keep it hand-started and nag instead.

So the daily `due` job decides whether the sweep is overdue
(`check_guard_sweep_due.is_overdue`) and this keeps ONE issue in step with that
answer: filed when it first goes overdue, commented on each later day it still
is, and closed by the first run after a sweep. One issue by exact title, never a
search, through the same code `say_when_ci_goes_red.py` keeps its own with.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from say_when_ci_goes_red import CannotAsk, _gh, file_once, open_titled  # noqa: E402

sys.path.insert(0, str(REPO_ROOT))
from tools.check_guard_sweep_due import OVERDUE_AFTER  # noqa: E402

#: No number in it. The threshold is OVERDUE_AFTER, and the issue is found by
#: this exact title, so a title quoting the threshold would turn false when the
#: constant moves, or orphan the open issue when it was corrected (L41).
OVERDUE_TITLE = "The guard sweep is overdue"
#: Labels the repository already has: a missing one makes `gh issue create`
#: refuse, so the nag would never arrive.
LABELS = ("ci", "priority-p2")


def _body(said: str) -> str:
    return (f"{said}\n\n"
            f"Overdue means no sweep for more than {OVERDUE_AFTER.days} days. "
            "The sweep re-proves every guard against things no commit here "
            "touches: the runner image, the pinned Xcode and Homebrew packages "
            "(#551). Start one with `gh workflow run guards.yml`. The next daily "
            "run after it closes this issue.")


def keep_the_overdue_issue_current(*, overdue: bool | None, said: str,
                                   run=None) -> tuple[str, int | None]:
    """File, comment on or close the one overdue issue. Returns what it did.

    `overdue` is None when the history could not be read, and then nothing is
    touched: closing the issue would say the sweep ran when nobody knows (L119).
    """
    if overdue is None:
        return ("could not tell, so left the issue as it is", None)
    if overdue:
        return file_once(OVERDUE_TITLE, _body(said), labels=LABELS, run=run)
    open_now = open_titled(OVERDUE_TITLE, run=run)
    for number in open_now:
        _gh(["issue", "close", str(number), "--reason", "completed",
             "--comment", f"The sweep has run again. {said}"], run=run)
    return ("closed", open_now[0]) if open_now else ("nothing to do", None)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--overdue", choices=("true", "false", "unknown"),
                        required=True)
    parser.add_argument("--said", required=True)
    args = parser.parse_args(argv)
    try:
        did, number = keep_the_overdue_issue_current(
            overdue={"true": True, "false": False, "unknown": None}[args.overdue],
            said=args.said)
    except CannotAsk as refusal:
        # Red, not a warning: this job's whole purpose today is the nag, and a
        # nag that could not be delivered must not read as one that was (L98).
        print(f"::error::could not keep the overdue issue current: {refusal}")
        return 1
    print(f"{did}" + (f" #{number}" if number else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
