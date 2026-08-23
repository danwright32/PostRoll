"""Say when a merge touched something only the hand check can see (#878).

`docs/HAND-CHECK.md` holds the questions nothing automated can answer: the
window's lifecycle, whether Return commits a hand opened form but not a link
raised one, what the alerts draw, the quit confirmation, and what the Dock says
while work is running. Before this, nothing told anybody to run it. The only
references anywhere were the README and the script itself, so a change to
`MainWindowView`, `WindowModals`, `PostRollApp.swift`, `NotificationService` or
`WorkingDockTile` landed with no reminder at all, and those files have no other
reviewer.

It does not gate. A merge is not blocked and nothing fails: the answer is a
sentence in the merge's own run saying which steps now cover code that just
changed. Gating on a twenty minute manual routine would make it something to
route around, which is how a checklist dies.

## Where the mapping lives, and why

In the checklist, one `Covers:` line per step, rather than in a table here. A
list that has to mirror another source of truth is derived from it, never kept
by hand beside it (L41). The failure mode of a table here is silent and points
the wrong way: a step whose files nobody added is a step nothing ever prompts,
and it looks exactly like a step whose files were not touched.

## Every way it can say nothing, and why none of them are quiet

Being handed no changed files is an ERROR, not an empty answer: a merge always
changes something, so an empty list means whatever computed it failed, and
"nothing to run" is the reassuring reading of a broken step (L98). A checklist
with no steps is an error for the same reason. A step naming a file that is not
in the repo is an error too, because a moved file leaves that step silent on
exactly the change that should raise it, while the tool reports itself healthy
(L100). Only a real diff that genuinely touches nothing covered prints the
sentence saying so, and it does print one.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CHECKLIST = REPO_ROOT / "docs" / "HAND-CHECK.md"

HEADING = re.compile(r"^## (\d+)\. (.+?)\s*$")
COVERS = re.compile(r"^Covers:\s*(.*)$")
PATH_IN_TICKS = re.compile(r"`([^`]+)`")


@dataclass
class Step:
    """One numbered step, and the files it is the only reviewer of."""

    number: int
    title: str
    covers: list[str] = field(default_factory=list)


def read_steps(checklist: Path) -> list[Step]:
    """Every step in the checklist, with the paths it declares.

    The `Covers:` block runs from its own line to the next blank one, so a long
    list can wrap rather than living on one unreadable line. Paths are read out
    of backticks, which is how the rest of the document writes a filename, so
    prose in the same block cannot be mistaken for one.
    """
    steps: list[Step] = []
    in_covers = False

    for line in checklist.read_text().splitlines():
        heading = HEADING.match(line)
        if heading:
            steps.append(Step(number=int(heading.group(1)), title=heading.group(2)))
            in_covers = False
            continue
        if not steps:
            continue
        covers = COVERS.match(line)
        if covers:
            in_covers = True
            steps[-1].covers.extend(PATH_IN_TICKS.findall(covers.group(1)))
            continue
        if in_covers:
            if not line.strip():
                in_covers = False
                continue
            steps[-1].covers.extend(PATH_IN_TICKS.findall(line))

    return steps


def steps_for(changed: list[str], steps: list[Step]) -> list[tuple[Step, list[str]]]:
    """The steps a diff raises, with the files that raised each one.

    A file is reported against EVERY step that names it, not the first: the
    alerts and the recovery behind them are two steps over one set of files,
    and naming only one sends somebody to run half of what the change affected.
    """
    raised = []
    for step in steps:
        touched = [path for path in changed if path in step.covers]
        if touched:
            raised.append((step, touched))
    return raised


def report(raised: list[tuple[Step, list[str]]]) -> str:
    if not raised:
        return (
            "This merge touched no file the hand check is the only reviewer of, "
            "so no step of docs/HAND-CHECK.md is prompted by it."
        )

    lines = [
        "This merge touched code nothing automated can see. "
        "Run these steps of docs/HAND-CHECK.md after `make install`:",
        "",
    ]
    for step, touched in raised:
        lines.append(f"Step {step.number}: {step.title}")
        for path in touched:
            lines.append(f"  raised by {path}")
        lines.append("")
    lines.append(
        "It does not gate anything. Nothing here failed, and nothing here has "
        "been checked either: these are the questions no suite can answer."
    )
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("changed", nargs="*", help="the paths this merge changed")
    parser.add_argument("--checklist", type=Path, default=DEFAULT_CHECKLIST)
    parser.add_argument(
        "--root",
        type=Path,
        default=REPO_ROOT,
        help="where the declared paths are resolved from, for tests",
    )
    arguments = parser.parse_args(argv)

    if not arguments.changed:
        print(
            "no changed files were given, so this ran against nothing. A merge "
            "always changes something, so an empty list is a broken caller "
            "rather than a merge that needs no hand check.",
            file=sys.stderr,
        )
        return 2

    if not arguments.checklist.exists():
        print(f"there is no checklist at {arguments.checklist}, so nothing was read.",
              file=sys.stderr)
        return 2

    steps = read_steps(arguments.checklist)
    if not steps:
        print(
            f"{arguments.checklist} holds no steps at all, so every change would "
            "be reported as needing no hand check. That is the reassuring answer "
            "to a file that has stopped saying anything.",
            file=sys.stderr,
        )
        return 2

    missing = [
        (step.number, path)
        for step in steps
        for path in step.covers
        if not (arguments.root / path).exists()
    ]
    if missing:
        for number, path in missing:
            print(f"step {number} names {path}, which is not in the repo.", file=sys.stderr)
        print(
            "A step pointing at a moved file is silent on exactly the change "
            "that should raise it, so the mapping is repaired rather than used.",
            file=sys.stderr,
        )
        return 2

    print(report(steps_for(arguments.changed, steps)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
