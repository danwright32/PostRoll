#!/usr/bin/env python3
"""Re-measure the numbers an open issue was written on (#1033).

Issues here carry hard measured figures, and the plans built from them rest on
those figures. Nothing re-measured them. #991 recorded 58 cache entries holding
16 GB; measured on 2026-08-29 it was 76 entries holding 20.9 GB, 30 percent out
after roughly a day. A previous session found three of six premises in one issue
did not survive checking.

A number with a date on it reads as MORE trustworthy, not less (L316, L244,
L210), so the remedy is not to date them harder. It is to re-take the reading.

## Why a NAMED measurement rather than a recorded command

The issue proposed recording the command beside the number and re-running it.
That would make an issue body, which anybody with write access can edit and
which arrives from outside this repository, into a shell command this tool runs
holding a token. A figure being checkable is not worth a remote execution
surface.

So an issue cites a measurement by NAME, from the small list below, and the tool
knows how to take each one. A name it does not know is reported as unknown
rather than skipped, because a marker nobody can act on and a marker that agrees
are otherwise the same silence (L98).

## The marker

An HTML comment, so it does not clutter the rendered issue:

    <!-- remeasure: guard-entries = 495 +/- 10% -->

Anything the pattern does not match is not a marker, and a body with no marker
is an issue nobody claimed carried a re-measurable figure.

## The empty case

No open issue carrying a marker is a legitimate state, and it is today's:
measured 2026-09-04, none of the eleven open issues rests on a figure in the
list below, because the ones that did have been closed. So that case is a
NOTICE rather than a warning. It still speaks, because a feature whose data is
empty ships inert and nothing distinguishes it from one that is working (L543),
but it does not cry wolf about a correct state on every run (L36).

## It warns, it does not gate

A figure having moved does not make the change being merged wrong, and failing a
run for it is how a check teaches everybody to bypass it (L36). Same shape as
`tools/check_guard_sweep_freshness.py`: an Actions warning annotation and a job
summary line, both visible on the run page without blocking.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

#: `<!-- remeasure: <name> = <value> +/- <tolerance>% -->`
#:
#: The value is read as a plain number so a figure written with thousands
#: separators or a unit is NOT matched: a marker that half parses would compare
#: against something nobody wrote.
MARKER = re.compile(
    r"<!--\s*remeasure:\s*([a-z][a-z0-9-]*)\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*"
    r"\+/-\s*([0-9]+(?:\.[0-9]+)?)%\s*-->")


class CannotMeasure(Exception):
    """The reading could not be taken, which is not the same as it agreeing.

    Its own type, because a silently failing re-measure reports every figure as
    still true and is indistinguishable from a healthy check (L98, L11).
    """


def _gh(args: list[str], run=None) -> str:
    runner = run or (lambda a: subprocess.run(a, capture_output=True, text=True))
    done = runner(["gh", *args])
    if done.returncode != 0:
        raise CannotMeasure(f"gh {' '.join(args[:3])} failed: "
                            f"{(done.stderr or done.stdout).strip()[:200]}")
    return done.stdout


def guard_entries(run=None) -> float:
    """How many guards the mutation registry holds."""
    found = list((REPO_ROOT / "tests" / "fixtures" / "guard_mutations").glob("*.json"))
    if not found:
        raise CannotMeasure(
            "the guard registry directory holds no entries, which is not this "
            "repository: the reading would report a collapse that has not "
            "happened")
    return float(len(found))


def swift_tests(run=None) -> float:
    """The recorded Swift suite size."""
    record = REPO_ROOT / "tests" / "fixtures" / "swift_suite_count.json"
    if not record.exists():
        raise CannotMeasure(f"{record.name} is not there, so there is no "
                            f"recorded count to compare against")
    held = json.loads(record.read_text(encoding="utf-8"))
    for key in ("count", "tests", "swift_tests"):
        if key in held:
            return float(held[key])
    raise CannotMeasure(f"{record.name} names no count under any key this "
                        f"knows, so its shape has changed")


def cache_entries(run=None) -> float:
    """How many Actions caches this repository holds."""
    raw = _gh(["api", "repos/:owner/:repo/actions/caches", "-q", ".total_count"],
              run=run)
    return float(raw.strip())


def cache_bytes(run=None) -> float:
    """How much those caches hold, in gigabytes."""
    raw = _gh(["api", "repos/:owner/:repo/actions/caches", "--paginate",
               "-q", ".actions_caches[].size_in_bytes"], run=run)
    total = sum(int(line) for line in raw.split() if line.strip())
    return total / 1_000_000_000


def open_issues(run=None) -> float:
    """How many issues are open."""
    raw = _gh(["issue", "list", "--state", "open", "--limit", "500",
               "--json", "number"], run=run)
    return float(len(json.loads(raw)))


#: Every figure this can re-take, by the name an issue cites.
#:
#: Small and named on purpose. The alternative the issue proposed, running a
#: command recorded in the body, turns an issue into something this executes.
MEASUREMENTS = {
    "guard-entries": guard_entries,
    "swift-tests": swift_tests,
    "cache-entries": cache_entries,
    "cache-gb": cache_bytes,
    "open-issues": open_issues,
}


def markers(body: str) -> list[tuple[str, float, float]]:
    return [(name, float(value), float(tolerance))
            for name, value, tolerance in MARKER.findall(body or "")]


def issues_with_figures(run=None) -> list[dict]:
    raw = _gh(["issue", "list", "--state", "open", "--limit", "300",
               "--json", "number,title,body"], run=run)
    found = []
    for issue in json.loads(raw):
        cited = markers(issue.get("body") or "")
        if cited:
            found.append({"number": issue["number"], "title": issue["title"],
                          "figures": cited})
    return found


def drifted(recorded: float, now: float, tolerance: float) -> bool:
    if recorded == 0:
        return now != 0
    return abs(now - recorded) / abs(recorded) * 100 > tolerance


def check(run=None) -> tuple[list[str], list[str], int]:
    """`(moved, unreadable, checked)`.

    Two lists, not one, because they need opposite responses: a figure that
    MOVED is a plan to re-examine, and a figure that could not be READ is this
    tool being broken (L11).
    """
    try:
        subjects = issues_with_figures(run=run)
    except CannotMeasure as refusal:
        return ([], [f"could not list the open issues at all: {refusal}"], 0)

    moved, unreadable, checked = [], [], 0
    for issue in subjects:
        for name, recorded, tolerance in issue["figures"]:
            take = MEASUREMENTS.get(name)
            if take is None:
                unreadable.append(
                    f"#{issue['number']} cites '{name}', which nothing here "
                    f"knows how to measure. Known: {sorted(MEASUREMENTS)}")
                continue
            try:
                now = take(run=run)
            except CannotMeasure as refusal:
                unreadable.append(f"#{issue['number']} '{name}': {refusal}")
                continue
            checked += 1
            if drifted(recorded, now, tolerance):
                moved.append(
                    f"#{issue['number']} was written on {name} = {recorded:g} "
                    f"and it is now {now:g}, past the {tolerance:g}% it allows: "
                    f"{issue['title']}")
    return moved, unreadable, checked


def main(argv: list[str] | None = None) -> int:
    argparse.ArgumentParser(description=__doc__.split("\n")[0]).parse_args(argv)
    moved, unreadable, checked = check()

    lines = []
    for line in unreadable:
        # Its own annotation, and first: a re-measure that could not run says
        # nothing about whether the figure still holds, and reading it as
        # agreement is the failure this whole tool is about.
        lines.append(f"::warning::could not re-measure: {line}")
    for line in moved:
        lines.append(f"::warning::{line}")

    if not lines and checked:
        lines.append(f"{checked} recorded figure(s) re-measured, none moved")
    elif not lines:
        # A NOTICE, not a warning, and the difference is the point.
        #
        # It must not read as "none moved": a feature whose data is empty ships
        # inert and nothing distinguishes it from one that is working (L543), so
        # it says so out loud. But no open issue carrying a marker is the
        # LEGITIMATE state today (measured 2026-09-04: none of the eleven open
        # issues rests on a figure this can take, because the ones that did have
        # been closed), and a warning on every scheduled run about a correct
        # state is what teaches a person to skip the whole list (L36).
        lines.append("::notice::armed, and no open issue records a "
                     "re-measurable figure yet, so nothing was checked. Add a "
                     "marker like <!-- remeasure: guard-entries = 495 +/- 10% "
                     "--> to an issue whose plan rests on a number")

    for line in lines:
        print(line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("### Recorded figures\n\n"
                     + "\n".join(f"- {line.removeprefix('::warning::')}"
                                 for line in lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
