"""The sweep's staleness window and its watchdog's window are ONE rule (#1259).

Two numbers decide how often the guard sweep runs when nothing has changed:

    tools/check_guard_sweep_due.UNCONDITIONAL_AFTER   how long a proof stands
    tools/check_guard_sweep_freshness.DEFAULT_WINDOW  how long silence is normal

They are not independent. The watchdog exists to notice the schedule having
STOPPED, so its window has to be longer than the longest gap between proofs
that is not a fault, which is the staleness window. Shorter, and it fires on a
repository that is merely quiet, which is the alarm that teaches everyone to
ignore the whole list (L36, L144: a monitor must judge by the same predicate
the action decided by).

That was written down and left to a person: the comment on DEFAULT_WINDOW said
"Both numbers move together or neither does", which is a rule living in prose
and reaching nothing (L27, L41). One of them is derived from the other now, and
this file is what holds the relationship.

## Why the value moved, and why it is safe

Measured 2026-09-04: one full sweep costs about 144 macOS minutes, and a
private repository on the free plan has 200 a month once the ten times macOS
multiplier is applied. At a seven day floor that is 620 a month, three times
the whole allowance before a single pull request runs.

Stretching it costs nothing while the repository is active, and that is not a
judgement, it is what the code does: `decide` reaches the staleness branch ONLY
when the tree has already been proved. Any day main moved is TREE_NOT_PROVED
and sweeps regardless of the window. The window is dead code on a busy repo and
is the whole cost on a quiet one, which is the state PostRoll is heading for.
`test_the_window_cannot_delay_a_sweep_after_a_merge` is the control on that
claim rather than the paragraph being trusted.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from tools.check_guard_sweep_due import Due, UNCONDITIONAL_AFTER, decide
from tools.check_guard_sweep_freshness import DEFAULT_WINDOW
from tools.guard_sweep_history import Sweep

NOW = datetime(2026, 9, 4, 12, 0, tzinfo=timezone.utc)
TREE = "a" * 40
OTHER = "b" * 40

#: GitHub disables a repository's scheduled workflows after 60 days with no
#: push, and reports that nowhere (#554). A watchdog whose window reaches past
#: that fires only after the schedule is already off, so it reports the
#: consequence rather than the cause.
GITHUB_DISABLES_A_SCHEDULE_AFTER = timedelta(days=60)


def proof(days_ago: float, *, sha: str = TREE, shard: int = 1) -> Sweep:
    return Sweep(run_id=100, head_sha=sha, created_at=NOW - timedelta(days=days_ago),
                 event="schedule", ran_shards=frozenset({shard}),
                 passed_shards=frozenset({shard}))


# ── the relationship, which is the point of this file ────────────────────────


def test_the_watchdog_waits_longer_than_a_quiet_repo_takes_to_sweep():
    """The one that must never stop being true.

    A watchdog window inside the staleness window accuses a repository that is
    working exactly as designed: the sweep is not due yet, so it has not run,
    so the watchdog calls it stopped. There is no action that clears that,
    because running the sweep makes it decline again (L144).
    """
    assert DEFAULT_WINDOW > UNCONDITIONAL_AFTER, (
        f"the watchdog fires after {DEFAULT_WINDOW.days} days of silence while "
        f"a proof stands for {UNCONDITIONAL_AFTER.days}, so a quiet repository "
        f"is reported as a stopped schedule and nothing anybody does clears it")


def test_the_watchdog_speaks_before_github_switches_the_schedule_off():
    """The other end of the same rule.

    The watchdog exists because a schedule's failure mode is silence, and the
    loudest version of that silence is GitHub disabling it outright. A window
    reaching past 60 days would report the schedule as stopped only once it
    actually had been, which is the one outcome this cannot be late for.
    """
    assert DEFAULT_WINDOW < GITHUB_DISABLES_A_SCHEDULE_AFTER, (
        f"the watchdog waits {DEFAULT_WINDOW.days} days, and GitHub disables a "
        f"schedule after {GITHUB_DISABLES_A_SCHEDULE_AFTER.days} with no push, "
        f"so it can only ever report a schedule that is already off")


def test_the_two_windows_leave_room_for_one_missed_sweep():
    """Between the two bounds there has to be actual space, or the watchdog is
    either an alarm on normal operation or an alarm that arrives too late. The
    margin is what one missed sweep is allowed to use up."""
    margin = DEFAULT_WINDOW - UNCONDITIONAL_AFTER

    assert margin >= timedelta(days=7), (
        f"only {margin.days} days separate a proof going stale from the "
        f"watchdog calling the schedule dead, so a single delayed run is an "
        f"alarm. GitHub delays scheduled work by hours under load and a run "
        f"can be lost entirely (L386)")


def test_the_watchdog_window_is_derived_rather_than_restated():
    """The reason this file exists.

    Both numbers were written out separately with a comment asking whoever
    changed one to change the other. A rule that lives in a comment reaches
    nothing (L27), and these two drifting apart is silent in both directions.
    """
    import inspect
    import tools.check_guard_sweep_freshness as freshness

    source = inspect.getsource(freshness)
    at = source.index("DEFAULT_WINDOW =")
    assignment = source[at:source.index("\n", at)]

    assert "UNCONDITIONAL_AFTER" in assignment, (
        f"DEFAULT_WINDOW is written out as its own number ({assignment!r}) "
        f"rather than derived from the staleness window it has to stay longer "
        f"than, so the two can drift with nothing reporting it")


# ── the control on why stretching the window is safe ─────────────────────────


def test_the_window_cannot_delay_a_sweep_after_a_merge():
    """The claim the value change rests on, measured rather than asserted.

    The staleness branch is reached ONLY when this tree has already been
    proved. A tree that moved is TREE_NOT_PROVED and sweeps whatever the window
    says, so lengthening the window cannot delay a single sweep on any day main
    moved. If this ever stops holding, the window becomes a real coverage
    decision instead of a dead branch on a busy repository.
    """
    a_year = timedelta(days=365)

    moved = decide(sha=OTHER, shard=1, history=[proof(0.5)], now=NOW,
                   unconditional_after=a_year)

    assert moved.due is Due.TREE_NOT_PROVED
    assert moved.run is True, (
        "a tree nobody has proved was skipped because the staleness window was "
        "long, so the window is no longer dead code on a repository that moves")


def test_an_unchanged_tree_inside_the_window_still_skips():
    proved = decide(sha=TREE, shard=1,
                    history=[proof(UNCONDITIONAL_AFTER.days - 1)], now=NOW,
                    unconditional_after=UNCONDITIONAL_AFTER)

    assert proved.due is Due.ALREADY_PROVED


def test_an_unchanged_tree_past_the_window_sweeps_anyway():
    """The runner image, the pinned Xcode and Homebrew packages all move with
    no commit here, so an unchanged tree is not an unchanged proof (#551).
    Stretching the window does not remove that, it only spaces it out."""
    stale = decide(sha=TREE, shard=1,
                   history=[proof(UNCONDITIONAL_AFTER.days + 1)], now=NOW,
                   unconditional_after=UNCONDITIONAL_AFTER)

    assert stale.due is Due.PROOF_IS_STALE
    assert stale.run is True


def test_the_window_is_wide_enough_to_fit_the_allowance():
    """What the value has to satisfy, written as the arithmetic rather than as
    a number somebody chose.

    A sweep costs about 144 macOS minutes, measured 2026-09-04 across the seven
    shards. A private repository on the free plan gets 2,000 allowance minutes
    a month and macOS draws ten of them per minute, so 200 macOS minutes. At a
    seven day floor the sweep alone is 620 a month and nothing else can run.
    """
    a_sweep_costs = 144           # macOS minutes, measured 2026-09-04
    monthly_allowance = 2000 / 10  # macOS minutes on GitHub Free, private

    sweeps_a_month = 30 / UNCONDITIONAL_AFTER.days
    spent = sweeps_a_month * a_sweep_costs

    assert spent <= monthly_allowance, (
        f"an unchanged tree is swept every {UNCONDITIONAL_AFTER.days} days, "
        f"which is {spent:.0f} macOS minutes a month against an allowance of "
        f"{monthly_allowance:.0f}, so a quiet month cannot pay for a single "
        f"pull request on top (#1259)")
