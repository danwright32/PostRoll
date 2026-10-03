#!/usr/bin/env python3
"""Put a red run somewhere a person will see it (#1011).

No workflow here had any failure path. Grepping all four for `if: failure()`, a
notify step or an issue-opening step returned nothing, so a red run sat in the
Actions tab until somebody opened it.

Most checks run on a pull request, where a failure blocks the merge and cannot
be missed. Three do not:

- `guards.yml`'s `full` job, the full sweep, runs only when somebody starts it
  by hand (#1428), never on a pull request. It cannot gate anything: a failure
  means a guard is already dead on main.
- The sweep exists precisely because the proofs depend on things no commit
  touches, the runner image, the pinned Xcode and Homebrew packages. There is
  no pull request behind it, so nobody has a reason to look.
- `guards.yml`'s `due` job runs on the daily schedule and decides whether the
  sweep has anything to prove, with nobody watching it either.

It has happened. On 2026-08-19 the sweep had been dying at 60 minutes for hours
while the run list read as though somebody had superseded those runs, and every
guard in the registry had quietly stopped being re-proved. Two defects were
fixed then; that nothing told anybody was the third, and it was not.

## One issue per workflow, not one per run

The whole value of this is that it is worth reading, and the first flaky week
would teach everybody to skip it (L36). So there is ONE open issue per workflow,
found by an exact title, and a later failure comments on it rather than filing
again.

## It assumes it runs twice

Four shards can go red at once and each runs this, so two of them can look, find
nothing, and both create. That is handled rather than hoped about (L33): after
creating, it looks again, and if several exist it keeps the LOWEST numbered one,
closes the rest as duplicates and comments on the keeper. Whichever shard gets
there second converges on the same answer as the first.

## What it does not do

The other half of #1011, noticing that the sweep has stopped happening at all,
is `say_when_the_sweep_is_overdue.py` (#1466), which shares this file's one
issue logic.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys

#: The one open issue per workflow is found by this exact title.
#:
#: An exact string rather than a search over words, because a search is a
#: different question with a different answer: it can match an issue somebody
#: wrote about the same workflow and this would then comment on a human's
#: report instead of its own record (L521).
TITLE = "CI is red on {workflow}"

#: Labels every filed issue carries, so the repo's own field rules are met by
#: construction rather than by whoever reads it afterwards.
LABELS = ("ci", "priority-p1", "bug")


class CannotAsk(Exception):
    """GitHub could not be asked, which is not the same as nothing being wrong.

    Its own type, because a run that said "nothing to report" on a broken token
    would say it every time and read as a healthy repository (L11, L98).
    """


def _gh(args: list[str], run=None) -> str:
    runner = run or (lambda a: subprocess.run(a, capture_output=True, text=True))
    done = runner(["gh", *args])
    if done.returncode != 0:
        raise CannotAsk(f"gh {' '.join(args[:3])} failed: "
                        f"{(done.stderr or done.stdout).strip()[:300]}")
    return done.stdout


def open_titled(title: str, run=None) -> list[int]:
    """Every open issue whose title is exactly `title`, lowest first.

    Shared with `say_when_the_sweep_is_overdue.py`, which keeps its own one
    issue the same way, so there is one implementation of "the one issue"
    rather than two that can come to disagree (L41).
    """
    # Every open issue rather than a page of them: an existing report missed
    # because it sat past the page would be filed again every day.
    raw = _gh(["issue", "list", "--state", "open", "--limit", "1000",
               "--json", "number,title"], run=run)
    return sorted(issue["number"] for issue in json.loads(raw)
                  if issue["title"] == title)


def open_reports(workflow: str, run=None) -> list[int]:
    """Every open issue this tool has filed for `workflow`, lowest first."""
    return open_titled(TITLE.format(workflow=workflow), run=run)


def body(workflow: str, job: str, url: str) -> str:
    return (
        f"`{workflow}` went red.\n\n"
        f"- job: `{job}`\n"
        f"- run: {url}\n\n"
        f"This job does not gate a merge: it runs after the change has landed, "
        f"or on a schedule with no push behind it, so a red run here is a "
        f"failure already on main rather than one blocking anything.\n\n"
        f"One issue per workflow, updated rather than refiled, so a flaky week "
        f"does not bury the list. Close it once the run is green again."
    )


def file_once(title: str, text: str, labels=LABELS, run=None) -> tuple[str, int]:
    """File the one open issue called `title`, or comment on it if it exists."""
    existing = open_titled(title, run=run)
    if existing:
        keeper = existing[0]
        _gh(["issue", "comment", str(keeper), "--body", text], run=run)
        return ("commented", keeper)

    _gh(["issue", "create", "--title", title, "--body", text,
         "--label", ",".join(labels)], run=run)

    # Look again. Two shards failing at once can both have found nothing above
    # and both created, and a duplicate that nobody notices is how a list stops
    # being read (L33).
    after = open_titled(title, run=run)
    if len(after) > 1:
        keeper, *duplicates = after
        for number in duplicates:
            _gh(["issue", "close", str(number), "--reason", "not planned",
                 "--comment", f"Duplicate of #{keeper}, filed by another run "
                              f"at the same moment."], run=run)
        return ("deduplicated", keeper)
    if not after:
        raise CannotAsk(
            "the issue was created and is not in the open list a moment later, "
            "so nothing can be said about where this was recorded")
    return ("filed", after[0])


def report(workflow: str, job: str, url: str, run=None) -> tuple[str, int]:
    """File or update the one report for `workflow`. Returns what it did."""
    return file_once(TITLE.format(workflow=workflow), body(workflow, job, url),
                     run=run)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--run-url", required=True)
    args = parser.parse_args(argv)

    try:
        did, number = report(args.workflow, args.job, args.run_url)
    except CannotAsk as refusal:
        # A warning, not a failure. The job is ALREADY red; exiting non-zero
        # here would add a second red step saying nothing about the first, and
        # the thing worth reading would be buried under the thing that could not
        # report it (L11).
        print(f"::warning::could not record this failure as an issue: {refusal}")
        return 0

    print(f"{did} #{number} for {args.workflow}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
