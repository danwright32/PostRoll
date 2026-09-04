#!/usr/bin/env python3
"""Delete the branches whose pull request has already merged (#1043).

Measured 2026-08-30: origin held 123 branches, 118 of them the head of a MERGED
pull request. Measured again on 2026-09-04: 243.

They accumulate because this repo squash-merges. A squash creates a new commit
that does not descend from the branch, so `git branch --merged` reports none of
them as merged and the standard way of finding safe-to-delete branches finds
nothing. That is the trap rather than the clutter: the safe command does nothing,
so the reachable habit becomes `git branch -D`, which is the command that cannot
tell a merged branch from unfinished work.

## What makes a branch safe to delete here

Both of these, and neither alone:

- its pull request is MERGED, asked of GitHub rather than inferred from the
  commit graph, because the graph is exactly what a squash breaks;
- the branch carries nothing the merge did not take, which means its tip is
  either the head that merged or that pull request's own squash commit.

The second is what stops this destroying work. A branch can be the head of a
merged pull request AND have had new commits pushed to it since, which is an
ordinary way to start the follow-up: deleting on the merged state alone would
throw that away, and the branch would look identical to the 235 that are safe.

The squash commit has to count as well, and that is not a nicety. Measured on
2026-09-04, `meta-token-in-settings` sat at 8fa3b4e0, which is the merge commit
GitHub itself wrote for #1198: somebody pushed main back onto the branch after
merging. Judging on the head SHA alone called that new work and left it behind
forever, and the message said it had moved on, which was a claim about a commit
this repository wrote itself (L11).

## Recoverable

Measured, not assumed: GitHub keeps `refs/pull/N/head` after the branch is
gone. Checked on 2026-09-04 against #594, whose branch had already been
deleted, and its head commit still resolved. So a branch pruned by mistake
comes back with `git fetch origin refs/pull/<n>/head`. That is what makes a
run of 235 deletions a reasonable thing to do at all, and it is why the
MOVED check above is the part that carries the risk: a commit that was never
in a pull request is in no pull ref either.

## What this does NOT touch

Remote refs on origin, and nothing else. A local branch, and any worktree
standing on one, survives a prune untouched: this deletes exactly what GitHub's
own `delete_branch_on_merge` would have deleted at merge time, which is why
turning that on is the other half of this issue. Two branches live worktrees
were standing on were in the first real run's list, both with merged pull
requests, and both kept every local commit.

Dry run by default. `--delete` is the deliberate act.

    venv/bin/python tools/prune_merged_branches.py
    venv/bin/python tools/prune_merged_branches.py --delete
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys

#: Never deleted, whatever any pull request says about them.
#:
#: `main` is obvious. The rest is deliberately empty: every other branch here is
#: somebody's work, and the two conditions above are what decide, not a list of
#: names somebody has to keep current (L96).
PROTECTED = {"main"}


class CannotAsk(Exception):
    """GitHub could not be asked, which is not the same as there being nothing.

    Its own type, because a run that reported "no branches to prune" on a broken
    token would say it every time and read as a tidy repository (L11, L98).
    """


def _gh(args: list[str], run=None) -> str:
    runner = run or (lambda a: subprocess.run(a, capture_output=True, text=True))
    done = runner(["gh", *args])
    if done.returncode != 0:
        raise CannotAsk(f"gh {' '.join(args[:3])} failed: "
                        f"{(done.stderr or done.stdout).strip()[:200]}")
    return done.stdout


def branches(run=None) -> dict[str, str]:
    """Every branch on origin, name to tip commit."""
    raw = _gh(["api", "repos/:owner/:repo/branches", "--paginate",
               "-q", '.[] | {name, sha: .commit.sha}'], run=run)
    found = {}
    for line in raw.splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        found[entry["name"]] = entry["sha"]
    if not found:
        raise CannotAsk("no branches came back at all, which is not this "
                        "repository: something answered emptily rather than "
                        "failing")
    return found


def merged_heads(run=None) -> dict[str, set[str]]:
    """Each branch with a MERGED pull request, and the tips that carry no work.

    Asked of GitHub rather than derived from the commit graph, because a squash
    merge produces a commit that does not descend from the branch and every
    graph-based answer is therefore no.

    Two SHAs per branch, not one: the head that merged, and the squash commit
    the merge produced. A branch sitting on the second has had main pushed back
    onto it, which carries nothing the merge did not already take.
    """
    raw = _gh(["pr", "list", "--state", "merged", "--limit", "1000",
               "--json", "headRefName,headRefOid,mergeCommit,number"], run=run)
    found: dict[str, set[str]] = {}
    for pull in json.loads(raw):
        # The NEWEST merged pull request for a branch wins, because a branch
        # name can be reused and an older entry would name a commit the branch
        # has long since moved past.
        if pull["headRefName"] in found:
            continue
        taken = {pull["headRefOid"]}
        # Absent on a pull request GitHub merged in a way that recorded no
        # commit. Nothing is assumed in its place: an absent merge commit just
        # means the head SHA is the only tip that counts (L214).
        squashed = (pull.get("mergeCommit") or {}).get("oid")
        if squashed:
            taken.add(squashed)
        found[pull["headRefName"]] = taken
    return found


def prunable(run=None) -> tuple[list[str], list[str]]:
    """`(safe, moved)`: branches to delete, and merged ones that have moved on."""
    live = branches(run=run)
    merged = merged_heads(run=run)

    safe, moved = [], []
    for name, tip in sorted(live.items()):
        if name in PROTECTED or name not in merged:
            continue
        if tip in merged[name]:
            safe.append(name)
        else:
            moved.append(name)
    return safe, moved


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delete", action="store_true",
                        help="actually delete them; without this it only reports")
    args = parser.parse_args(argv)

    try:
        safe, moved = prunable()
    except CannotAsk as refusal:
        print(f"nothing pruned: {refusal}", file=sys.stderr)
        return 1

    print(f"{len(safe)} branches whose pull request merged and which carry "
          f"nothing the merge did not take")
    if moved:
        print(f"{len(moved)} merged but MOVED SINCE, left alone: "
              f"{', '.join(moved)}")
    if not safe:
        return 0
    if not args.delete:
        print("dry run. Re-run with --delete to remove them.")
        for name in safe[:20]:
            print(f"  {name}")
        return 0

    failed = []
    for name in safe:
        done = subprocess.run(
            ["gh", "api", "-X", "DELETE",
             f"repos/:owner/:repo/git/refs/heads/{name}"],
            capture_output=True, text=True)
        if done.returncode != 0:
            failed.append(f"{name}: {(done.stderr or done.stdout).strip()[:80]}")
    print(f"deleted {len(safe) - len(failed)} of {len(safe)}")
    for line in failed:
        print(f"  could not delete {line}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
