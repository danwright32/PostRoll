"""#1043: the branches whose pull request merged, and the ones that only look it.

243 branches on origin as of 2026-09-04, because this repo squash-merges and a
squash commit does not descend from the branch it came from, so
`git branch --merged` reports none of them. The tool asks GitHub for the pull
request state instead.

The dangerous case, and the one every test here is really about: a branch whose
pull request MERGED and which has since had new commits pushed to it. That is an
ordinary way to start a follow-up, it is indistinguishable from the other 240 by
merged state alone, and deleting it destroys unpushed-anywhere work.

Nothing here reaches GitHub. Every test drives the tool with a fake `run` (L2).
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

from prune_merged_branches import (  # noqa: E402
    CannotAsk, branches, merged_heads, prunable)


def answers(branch_rows, pull_rows, branches_code=0, pulls_code=0):
    """A stand-in for `gh` that replies from the two lists given."""
    def run(args):
        if args[1] == "api":
            out = "\n".join(json.dumps(row) for row in branch_rows)
            return subprocess.CompletedProcess(args, branches_code, out, "boom")
        return subprocess.CompletedProcess(
            args, pulls_code, json.dumps(pull_rows), "boom")
    return run


def branch(name, sha):
    return {"name": name, "sha": sha}


def merged(name, sha, number=1, squash="sq"):
    return {"headRefName": name, "headRefOid": sha, "number": number,
            "mergeCommit": None if squash is None else {"oid": squash}}


def test_a_branch_whose_pull_request_merged_at_this_tip_is_safe():
    safe, moved = prunable(run=answers([branch("done", "aaa")],
                                       [merged("done", "aaa")]))

    assert safe == ["done"]
    assert moved == []


def test_a_merged_branch_that_gained_commits_since_is_left_alone():
    """The whole reason this is not a one-line loop. The branch is the head of a
    genuinely merged pull request, so every merged-state test says delete, and
    the commits pushed after the merge exist nowhere else."""
    safe, moved = prunable(run=answers([branch("followup", "bbb")],
                                       [merged("followup", "aaa")]))

    assert safe == [], "it deleted work pushed after the merge"
    assert moved == ["followup"]


def test_a_branch_sitting_on_its_own_squash_commit_is_safe():
    """Somebody pushed main back onto the branch after merging, so its tip is
    the commit GitHub wrote for that very pull request. It carries nothing the
    merge did not take.

    Measured, not invented: `meta-token-in-settings` was at 8fa3b4e0 on
    2026-09-04, which is #1198's own merge commit. Judged on the head SHA alone
    it read as new work and would have been left behind forever, with a message
    claiming it had moved on (L11)."""
    safe, moved = prunable(run=answers(
        [branch("pushed-back", "sq")], [merged("pushed-back", "aaa",
                                               squash="sq")]))

    assert safe == ["pushed-back"]
    assert moved == []


def test_a_merged_pull_request_with_no_recorded_merge_commit_still_works():
    """Nothing is assumed in the absent field's place: the head SHA is then the
    only tip that counts, which is the safe reading (L214)."""
    safe, moved = prunable(run=answers(
        [branch("done", "aaa"), branch("other", "bbb")],
        [merged("done", "aaa", squash=None),
         merged("other", "aaa", squash=None)]))

    assert safe == ["done"]
    assert moved == ["other"], (
        "an absent merge commit must not become a wildcard that matches any tip")


def test_a_branch_with_no_merged_pull_request_is_untouched():
    safe, moved = prunable(run=answers([branch("in-flight", "ccc")], []))

    assert (safe, moved) == ([], [])


def test_main_is_never_deleted_however_it_looks():
    """`main` is the head of nothing, but a reused branch name or an odd
    repository state must not be able to reach it (L9)."""
    safe, _ = prunable(run=answers([branch("main", "aaa")],
                                   [merged("main", "aaa")]))

    assert safe == []


def test_the_newest_merged_pull_request_decides_a_reused_name():
    """`gh pr list` returns newest first. An older pull request for the same
    branch name names a commit the branch has long since moved past, and taking
    it would report the branch as moved and leave it forever (L334)."""
    safe, moved = prunable(run=answers(
        [branch("recycled", "new")],
        [merged("recycled", "new", 2), merged("recycled", "old", 1)]))

    assert safe == ["recycled"]
    assert moved == []


def test_a_failed_branch_listing_refuses_rather_than_reporting_nothing():
    """A broken token, a rate limit or a network failure must not read as a
    repository with nothing to prune (L11, L98)."""
    with pytest.raises(CannotAsk):
        branches(run=answers([], [], branches_code=1))


def test_a_failed_pull_request_listing_refuses_too():
    """The other call, because a fallback written for one flavour of failure is
    absent in the neighbouring one (L173). If this returned empty, every branch
    would read as having no merged pull request, which is the SAFE direction
    here, and that is exactly why it would never be noticed."""
    with pytest.raises(CannotAsk):
        merged_heads(run=answers([], [], pulls_code=1))


def test_an_empty_branch_listing_is_a_refusal_not_a_clean_repository():
    """Something answered emptily rather than failing. This repository always
    has at least `main`, so zero branches is the tool being lied to (L98)."""
    with pytest.raises(CannotAsk):
        branches(run=answers([], []))


def test_an_empty_merged_listing_is_an_ordinary_answer():
    """The other direction (L159). A repository where nothing has merged yet is
    real, so this must NOT refuse, or the tool could never run on a young repo."""
    assert merged_heads(run=answers([], [])) == {}


def test_a_pull_request_for_a_branch_that_no_longer_exists_is_not_invented():
    """Deleted already, by a previous run or by hand. It must not appear in
    either list, because a name in `safe` is a name the tool will try to
    delete."""
    safe, moved = prunable(run=answers([branch("main", "aaa")],
                                       [merged("gone", "zzz")]))

    assert (safe, moved) == ([], [])
