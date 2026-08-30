"""#989: the full guard sweep runs once a day when main moved, not once a merge.

The sweep re-proved all 433 guards on every push to main: four macOS runners
for 21 to 29 minutes, 33 times in the week of 2026-08-22, which is 3,079 of the
6,207 macOS runner-minutes this repository spent and 50% of them. Nothing waits
on it. It runs AFTER the merge, and the entries a merge touched were already
proved on the pull request by the `changed` job. What it bought was the same
tree proved again within minutes rather than within a day, on a signal nobody
reads at either cadence, and what it cost was the runners every pull request
then queued behind: median wall clock 22.4 minutes against a longest single job
of 11.1 minutes, so over eight of those minutes were spent waiting for a runner
this job was holding.

So the cadence became a daily schedule and this is the gate on it. It answers
one question per shard: has THIS tree already been proved by THIS shard.

## Every uncertain answer runs the sweep

There are four outcomes and three of them run. A tree nobody has proved runs, a
history that could not be read runs, and a proof older than the unconditional
window runs even when nothing landed, because the proofs depend on things no
commit here touches: the runner image, the Xcode `PostRollApp/.ci-xcode-version`
pins, and Homebrew packages (#551). Only a tree this shard has actually proved,
recently, skips.

That asymmetry is the whole safety argument. The failure direction is a sweep
that runs when it could have skipped, which costs runner minutes; the direction
this must never take is a sweep that skips when it should have run, which stops
the guards being re-proved and reports nothing at all (L98).

## Why a SKIPPED proof step is not a proof

The gate makes the sweep's own steps conditional, so a run that skipped is still
a run, still `success`, still sitting at the top of the history with the tree's
sha on it. Read by sha alone it looks exactly like a tree that was proved, and
a gate that believed it would latch off permanently: every day's run would find
yesterday's skip, agree the tree was done, and skip again, forever, with the
workflow reporting green throughout (L98, L106: a liveness signal over dead
work). So a proof is a step that actually EXECUTED and passed, read off the
run's own step conclusions, never the run's.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from tools.guard_sweep_history import (
    PROOF_STEP,
    Sweep,
    proof_outcome,
    shard_of_job_name,
    sweeps_from_jobs,
)
from tools.check_guard_sweep_due import Due, Decision, decide

NOW = datetime(2026, 8, 30, 7, 0, tzinfo=timezone.utc)
WINDOW = timedelta(days=7)
TREE = "a" * 40
OTHER = "b" * 40


def sweep(sha: str = TREE, *, shard: int = 1, days_ago: float = 1.0,
          run_id: int = 100, passed: bool = True) -> Sweep:
    return Sweep(
        run_id=run_id,
        head_sha=sha,
        created_at=NOW - timedelta(days=days_ago),
        event="schedule",
        ran_shards=frozenset({shard}),
        passed_shards=frozenset({shard}) if passed else frozenset(),
    )


def call(history, *, shard: int = 1, sha: str = TREE) -> Decision:
    return decide(sha=sha, shard=shard, history=history, now=NOW,
                  unconditional_after=WINDOW)


# ── the one case that skips ───────────────────────────────────────────────────


def test_a_tree_this_shard_already_proved_is_not_due():
    assert call([sweep()]).due is Due.ALREADY_PROVED
    assert call([sweep()]).run is False


# ── everything else runs ──────────────────────────────────────────────────────


def test_a_tree_nobody_has_proved_is_due():
    result = call([sweep(sha=OTHER)])
    assert result.due is Due.TREE_NOT_PROVED
    assert result.run is True


def test_an_empty_history_is_due_rather_than_read_as_nothing_to_do():
    """An empty answer from a run-history query is not a verdict that the tree
    was proved; it is no evidence at all (L119)."""
    result = call([])
    assert result.run is True
    assert result.due is Due.TREE_NOT_PROVED


def test_another_shards_proof_does_not_answer_for_this_one():
    """Each shard proves a disjoint share of the registry, so shard 2's success
    says nothing about shard 3's entries (L70)."""
    assert call([sweep(shard=2)], shard=3).run is True


def test_a_skipped_proof_step_is_not_a_proof():
    """The case that would latch the gate off forever: a skipped run carries the
    tree's sha and concludes success, and believing it means every later day
    finds the previous day's skip and skips again."""
    skipped = Sweep(run_id=100, head_sha=TREE, created_at=NOW - timedelta(days=1),
                    event="schedule", ran_shards=frozenset(),
                    passed_shards=frozenset())
    result = call([skipped])
    assert result.run is True
    assert result.due is Due.TREE_NOT_PROVED


def test_a_failed_proof_leaves_the_tree_unproved():
    """A red shard is an unproved share of the registry, so tomorrow's run
    re-takes it rather than treating the attempt as the answer."""
    assert call([sweep(passed=False)]).run is True


def test_a_history_that_could_not_be_read_runs_and_says_which_it_was():
    """Distinct from an unproved tree, because the two call for different things
    and a shared message would leave the reader unable to tell a broken query
    from a real answer (L11)."""
    result = decide(sha=TREE, shard=1, history=None, now=NOW,
                    unconditional_after=WINDOW)
    assert result.run is True
    assert result.due is Due.HISTORY_UNREADABLE
    assert "could not be read" in result.message


def test_a_proof_older_than_the_window_runs_even_on_an_unchanged_tree():
    """The reason #551 gave the sweep a schedule in the first place: the runner
    image, the pinned Xcode and Homebrew packages all move with no commit here,
    so an unchanged tree is not an unchanged proof."""
    result = call([sweep(days_ago=WINDOW.days + 1)])
    assert result.run is True
    assert result.due is Due.PROOF_IS_STALE


def test_a_proof_exactly_on_the_window_still_counts():
    """Pinned, because an off by one here decides whether a quiet week gets one
    sweep or two."""
    assert call([sweep(days_ago=WINDOW.days)]).run is False


def test_the_staleness_window_is_measured_against_the_newest_proof_of_any_tree():
    """A sweep that proved a different tree yesterday is evidence the image and
    the toolchain still work, which is what the window is asking about."""
    history = [sweep(days_ago=WINDOW.days + 3), sweep(sha=OTHER, days_ago=0.5)]
    assert call(history).run is False


def test_the_newest_proof_decides_not_the_first_one_listed():
    """Nothing may depend on the API's ordering: an order assumption that
    happens to hold makes the answer right for a reason unrelated to the rule.

    Both entries prove the same tree, so ORDER is the only thing that separates
    the two answers: read newest first this is a fresh proof, read as listed it
    is a stale one.
    """
    stale = sweep(days_ago=WINDOW.days + 9, run_id=1)
    fresh = sweep(days_ago=0.5, run_id=2)
    assert call([stale, fresh]).due is Due.ALREADY_PROVED
    assert call([fresh, stale]).due is Due.ALREADY_PROVED


def test_the_message_always_names_the_shard_and_the_tree():
    """A gate line that does not say what it decided about leaves whoever reads
    the log knowing a sweep was skipped and with nowhere to go (L80)."""
    for history in ([], [sweep()], [sweep(days_ago=99)], None):
        message = decide(sha=TREE, shard=2, history=history, now=NOW,
                         unconditional_after=WINDOW).message
        assert "shard 2" in message
        assert TREE[:12] in message


def test_an_impossible_shard_is_refused_rather_than_answered():
    """A tool handed a target it cannot use must refuse, never quietly answer
    about something else (L320)."""
    with pytest.raises(ValueError):
        call([sweep()], shard=0)


# ── reading a proof out of what the jobs API actually returns ─────────────────


def job(name: str, *steps: tuple[str, str]) -> dict:
    return {"name": name,
            "steps": [{"name": n, "conclusion": c} for n, c in steps]}


def test_the_shard_number_comes_out_of_the_matrix_job_name():
    assert shard_of_job_name("full (3)") == 3
    assert shard_of_job_name("full") is None
    assert shard_of_job_name("changed") is None
    assert shard_of_job_name("swift-unit (2)") is None


def test_a_proof_step_that_ran_and_passed_is_a_proof():
    ran, passed = proof_outcome(job("full (1)", (PROOF_STEP, "success")))
    assert (ran, passed) == (True, True)


def test_a_proof_step_that_ran_and_failed_ran_but_did_not_pass():
    """The freshness check asks whether the sweep is still HAPPENING and the
    gate asks whether the tree is PROVED. A red shard answers yes to the first
    and no to the second, so the two are read as two values (L261)."""
    ran, passed = proof_outcome(job("full (1)", (PROOF_STEP, "failure")))
    assert (ran, passed) == (True, False)


def test_a_skipped_proof_step_neither_ran_nor_passed():
    ran, passed = proof_outcome(job("full (1)", (PROOF_STEP, "skipped")))
    assert (ran, passed) == (False, False)


def test_a_job_with_no_such_step_at_all_is_not_a_proof():
    """The step could be renamed. That must read as "no proof found" and run the
    sweep, not as a proof, and the name is asserted here so a rename goes red on
    something that names it rather than silently reporting every tree unproved
    forever."""
    ran, passed = proof_outcome(job("full (1)", ("Install ffmpeg", "success")))
    assert (ran, passed) == (False, False)


def test_the_proof_step_name_is_the_one_the_workflow_actually_runs():
    """Derived from the workflow rather than remembered here, because a name
    that matches nothing makes every run report an unproved tree and the sweep
    would run every day while reporting itself correct (L100)."""
    from pathlib import Path
    workflow = (Path(__file__).resolve().parent.parent
                / ".github" / "workflows" / "guards.yml").read_text(encoding="utf-8")
    assert f"- name: {PROOF_STEP}" in workflow


def test_a_run_is_summarised_by_which_shards_ran_and_which_passed():
    jobs = [job("full (1)", (PROOF_STEP, "success")),
            job("full (2)", (PROOF_STEP, "failure")),
            job("full (3)", (PROOF_STEP, "skipped")),
            job("changed", (PROOF_STEP, "success"))]
    summary = sweeps_from_jobs(
        run={"id": 7, "head_sha": TREE, "event": "schedule",
             "created_at": "2026-08-29T07:00:00Z"},
        jobs=jobs)
    assert summary.ran_shards == frozenset({1, 2})
    assert summary.passed_shards == frozenset({1})
    assert summary.run_id == 7


def test_an_unreadable_timestamp_on_a_run_is_not_read_as_now():
    """A stamp that cannot be parsed landing on the permissive side of the
    staleness window is the one way this could skip for a reason unrelated to
    the truth (L50)."""
    summary = sweeps_from_jobs(
        run={"id": 7, "head_sha": TREE, "event": "schedule",
             "created_at": "not a date"},
        jobs=[job("full (1)", (PROOF_STEP, "success"))])
    assert summary.created_at is None
    assert call([summary]).run is True
