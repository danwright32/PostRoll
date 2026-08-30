"""#990: a push to main does not re-run checks a pull request already passed.

Every one of the 60 most recent commits on main is a squash merge made by
`tools/wait_for_checks.py --merge`, which refuses a head that does not contain
main (exit 6, #680) and merges the exact commit it judged. A squash of a head
containing its base produces the head's tree byte for byte, so `tests.yml` and
`swift.yml` on a push to main re-run the pull request's checks against an
identical tree.

Measured on 2026-08-30 over the last 24 pushes to main, as job medians:

    Tests / macos                       481s   macOS
    macOS / swift-unit                  434s   macOS
    macOS / reference-frames (thursday) 170s   macOS
    macOS / reference-frames (goldens)  159s   macOS
    macOS / reference-frames (legibility) 130s macOS
    Tests / python                      206s   Linux

That is 23 macOS runner-minutes per merge, at 33 merges in the week to
2026-08-30. GitHub allows five concurrent macOS runners and a pull request here
asks for six, so those minutes come out of the queue every pull request sits in.

The premise was measured rather than assumed: over the 25 most recent merges,
each had exactly one associated pull request and the merged tree matched that
pull request's head tree in 25 of 25 cases.

## Every uncertain answer runs the job

Six outcomes and five of them run. The failure direction that costs money is a
job that runs when it could have skipped; the direction that costs coverage is a
job that skips when it should have run, and that one is silent (L98). So an
unreadable history runs, a commit with no associated pull request runs, one with
several runs (L521), a tree that differs runs, and a check that is anything but
green runs. Each says which it was in its own words, because a shared message
would leave the reader unable to tell a broken query from a real answer (L11).

An EMPTY association index in particular must never read as a pass: GitHub's
commit-to-pull-request association is a derived index that can be missing or
permanently incomplete, and a missing entry is indistinguishable from a commit
that really had no pull request (L119). Both run the job.

## Why the check is looked up by name on the head

The claim being made is narrow: this exact tree already had THIS check succeed.
Not that the pull request was green overall, which is a different and broader
claim that would let one job's proof stand in for another's.
"""

from __future__ import annotations

import pytest

from tools.check_tree_already_checked import (
    Answer,
    Decision,
    PullRequest,
    decide,
)

TREE = "t" * 40
OTHER_TREE = "u" * 40
HEAD = "h" * 40
CHECK = "swift-unit"


def pull_request(*, number: int = 7, tree: str = TREE,
                 checks: dict[str, str] | None = None) -> PullRequest:
    return PullRequest(
        number=number,
        head_sha=HEAD,
        tree_sha=tree,
        checks=dict(checks if checks is not None else {CHECK: "success"}),
    )


def call(pulls, *, tree: str = TREE, check: str = CHECK) -> Decision:
    return decide(tree=tree, check=check, pulls=pulls)


# ── the one answer that skips ────────────────────────────────────────────────

def test_a_tree_a_green_pull_request_already_carried_skips():
    decision = call([pull_request()])
    assert decision.answer is Answer.ALREADY_CHECKED
    assert not decision.run


def test_the_skip_names_the_pull_request_it_is_standing_on():
    """A person reading the log has to be able to go and check the claim."""
    decision = call([pull_request(number=1042)])
    assert "1042" in decision.message
    assert CHECK in decision.message


# ── the five that run ────────────────────────────────────────────────────────

def test_an_unreadable_history_runs_the_job():
    """`None` is not an empty list and must never arrive as one (L119)."""
    decision = call(None)
    assert decision.answer is Answer.HISTORY_UNREADABLE
    assert decision.run


def test_a_commit_with_no_associated_pull_request_runs_the_job():
    decision = call([])
    assert decision.answer is Answer.NO_PULL_REQUEST
    assert decision.run


def test_a_commit_with_several_associated_pull_requests_runs_the_job():
    """Many matches is this gate's own refusal, never absence (L521)."""
    decision = call([pull_request(number=1), pull_request(number=2)])
    assert decision.answer is Answer.SEVERAL_PULL_REQUESTS
    assert decision.run


def test_a_pull_request_whose_head_carries_a_different_tree_runs_the_job():
    decision = call([pull_request(tree=OTHER_TREE)])
    assert decision.answer is Answer.TREE_DIFFERS
    assert decision.run


def test_a_check_that_never_ran_on_that_head_runs_the_job():
    decision = call([pull_request(checks={})])
    assert decision.answer is Answer.CHECK_NOT_GREEN
    assert decision.run


@pytest.mark.parametrize("conclusion",
                         ["failure", "cancelled", "skipped", "timed_out",
                          "neutral", "action_required", "stale", ""])
def test_a_check_that_is_anything_but_success_runs_the_job(conclusion):
    """Only `success` is a proof. Everything else, named or not, runs.

    `skipped` matters most: once this gate ships, a skipped run is exactly what
    a merge produces, so a gate that read one as a proof would latch off
    permanently, every merge finding the last merge's skip and skipping again
    (L98, L106).
    """
    decision = call([pull_request(checks={CHECK: conclusion})])
    assert decision.answer is Answer.CHECK_NOT_GREEN
    assert decision.run


def test_another_job_being_green_is_not_this_job_being_green():
    """The claim is about THIS check, not about the pull request overall."""
    decision = call([pull_request(checks={"python": "success"})])
    assert decision.answer is Answer.CHECK_NOT_GREEN
    assert decision.run


# ── the messages are distinct, so a reader can tell the causes apart (L11) ───

def test_every_answer_has_its_own_wording():
    messages = {
        call(None).message,
        call([]).message,
        call([pull_request(number=1), pull_request(number=2)]).message,
        call([pull_request(tree=OTHER_TREE)]).message,
        call([pull_request(checks={})]).message,
        call([pull_request()]).message,
    }
    assert len(messages) == len(Answer), (
        "two outcomes share a message, so a reader cannot tell which happened")


def test_a_reason_that_ran_says_it_is_running_the_job():
    for pulls in (None, [], [pull_request(tree=OTHER_TREE)],
                  [pull_request(checks={})]):
        assert "runs" in call(pulls).message.lower(), call(pulls).message


# ── refusals rather than defaults (L320) ─────────────────────────────────────

def test_a_gate_asked_about_no_tree_refuses():
    with pytest.raises(ValueError, match="tree"):
        decide(tree="", check=CHECK, pulls=[pull_request()])


def test_a_gate_asked_about_no_check_refuses():
    with pytest.raises(ValueError, match="check"):
        decide(tree=TREE, check="", pulls=[pull_request()])


# ── the wiring in the workflow files ─────────────────────────────────────────
#
# The gate is only worth what the steps around it ask. Three things have to
# stay true, and none of them is visible from the module above:
#
# * Every step after the gate asks it. A step added later that does not is a
#   step that runs on every merge, and nothing about it looks wrong (L96).
# * Every one asks `!= 'false'`. Written `== 'true'` it would invert the safe
#   direction: the gate not running at all, or answering nothing, would then
#   SKIP the work rather than run it, silently, on the pull request path where
#   the gate is deliberately absent (L98, L72).
# * Every gated job ends with the step the duration series reads, or a skipped
#   job re-enters that series as a job that suddenly got fast (L102, L331).

import re
from pathlib import Path

from tools.check_tree_already_checked import (
    ASKS_THE_GATE,
    GATE_ID,
    WORK_STEP,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"


def _steps(job_body: str) -> list[str]:
    """Each step of one job, as the block of text it occupies."""
    blocks = re.split(r"\n(?=      - )", job_body)
    return [block for block in blocks if block.strip().startswith("- ")]


def _gated_jobs() -> dict[str, list[str]]:
    """Every job in every workflow that carries the gate, by `file::job`."""
    found = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        text = path.read_text(encoding="utf-8")
        after_jobs = text.split("\njobs:\n", 1)
        if len(after_jobs) != 2:
            continue
        for chunk in re.split(r"\n(?=  [a-z][a-z0-9-]*:\n)", after_jobs[1]):
            name = chunk.strip().split(":", 1)[0]
            if f"id: {GATE_ID}" not in chunk:
                continue
            found[f"{path.name}::{name}"] = _steps(chunk)
    return found


def test_the_gate_is_actually_wired_into_some_jobs():
    """Every check below is vacuous against a file where nothing is gated."""
    jobs = _gated_jobs()
    assert len(jobs) >= 4, (
        f"only {sorted(jobs)} carry the gate, so the checks below are "
        "measuring almost nothing")


def test_every_step_after_the_gate_asks_the_gate():
    for job, steps in sorted(_gated_jobs().items()):
        seen_gate = False
        for step in steps:
            if f"id: {GATE_ID}" in step:
                seen_gate = True
                continue
            if not seen_gate:
                continue
            name = step.split("\n")[0].strip()
            assert ASKS_THE_GATE in step, (
                f"{job}: the step {name!r} comes after the gate and does not "
                f"ask it, so it runs on every merge whatever the gate decided")


def test_no_step_asks_the_gate_the_unsafe_way_round():
    """`== 'true'` would make an absent answer skip the work rather than run it."""
    for path in sorted(WORKFLOWS.glob("*.yml")):
        text = path.read_text(encoding="utf-8")
        assert f"steps.{GATE_ID}.outputs.run == " not in text, (
            f"{path.name} tests the gate's answer for equality. Only "
            f"{ASKS_THE_GATE!r} is safe: the gate is deliberately absent on "
            "pull requests, and an absent answer must run the work")


def test_the_gate_only_fires_on_a_push():
    """On a pull request an up-to-date branch can carry its own head's tree, so
    a re-run would find the previous run's green and skip the check the merge
    is judged by."""
    for job, steps in sorted(_gated_jobs().items()):
        gate = next(s for s in steps if f"id: {GATE_ID}" in s)
        assert "if: github.event_name == 'push'" in gate, (
            f"{job}: the gate is not restricted to a push, so it can skip a "
            "check on the pull request that check exists to judge")


def test_every_gated_job_ends_with_the_step_the_duration_series_reads():
    for job, steps in sorted(_gated_jobs().items()):
        last = steps[-1]
        assert f"name: {WORK_STEP}" in last, (
            f"{job}: its last step is not {WORK_STEP!r}, so a merge that "
            "skipped this job's work reads in tools/check_job_durations.py as "
            "the job having become fast")


def test_the_confirming_step_still_runs_when_the_job_goes_red():
    """A job that got slower until it failed must stay in the series."""
    for job, steps in sorted(_gated_jobs().items()):
        last = steps[-1]
        assert "!cancelled()" in last, (
            f"{job}: {WORK_STEP!r} does not run on a failed job, so a red run "
            "drops out of the duration series, which hides a job getting "
            "slower right up to the moment it breaks")


def test_the_gate_asks_about_the_check_name_the_job_actually_publishes():
    """A gate asking about another job's check would let one job's green stand
    in for another's (L70)."""
    expected = {
        "tests.yml::python": '"python"',
        "tests.yml::macos": '"macos"',
        "swift.yml::swift-unit": '"swift-unit"',
        "swift.yml::reference-frames":
            '"reference-frames (${{ matrix.shard.name }})"',
    }
    for job, steps in sorted(_gated_jobs().items()):
        gate = next(s for s in steps if f"id: {GATE_ID}" in s)
        assert job in expected, f"{job} is gated and this check does not know it"
        assert f"--check {expected[job]}" in gate, (
            f"{job}: the gate asks about a check this job does not publish, so "
            f"it would let another job's result stand in for this one. Wanted "
            f"--check {expected[job]}")


def test_the_duration_series_knows_every_step_a_gate_can_skip():
    """`WORK_STEPS` is the whole reason a skipped job leaves the series.

    Derived from the workflows rather than compared against a second list: a
    gate added to a job whose terminal step is not in that tuple would be
    invisible, and the series would quietly start holding two populations
    again (L96, L102).
    """
    from tools.check_job_durations import WORK_STEPS

    for job, steps in sorted(_gated_jobs().items()):
        first_line = steps[-1].split("\n")[0]
        name = first_line.split("- name:", 1)[1].strip()
        assert name in WORK_STEPS, (
            f"{job} ends with the step {name!r}, which "
            "tools/check_job_durations.py does not know about, so a merge that "
            "skipped this job reads there as the job having become fast")
