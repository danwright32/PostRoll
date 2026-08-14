"""#554: notice when the weekly guard sweep stops running.

#551 added a `schedule` trigger so the full sweep re-proves every guard through
a quiet period, not only when something merges. A scheduled job has a failure
mode the merge sweep does not: its absence is invisible. GitHub disables a
repository's schedules after 60 days with no push and reports nothing at all
rather than reporting that it stopped, and a run that fails is only as visible
as GitHub's own email.

So the absence of an expected run has to be its own reported outcome (L13), and
"no scheduled run has ever happened" has to be distinguishable from "the last
one was long ago" (L98): the first is a schedule that has not come round yet,
the second is one that has stopped.

The clock is injected everywhere here. A fixture whose meaning is the
RELATIONSHIP between a stored date and now must pin both ends, or real time
walks the pair into a different case and the test passes while asserting about a
situation nobody chose (L130).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from tools.check_guard_sweep_freshness import Freshness, verdict

WINDOW = timedelta(days=14)
NOW = datetime(2026, 8, 14, 12, 0, tzinfo=timezone.utc)


def run_at(when: datetime) -> dict:
    return {"created_at": when.isoformat().replace("+00:00", "Z")}


def test_a_recent_scheduled_sweep_is_fresh():
    result = verdict([run_at(NOW - timedelta(days=3))], now=NOW, window=WINDOW)
    assert result.state is Freshness.FRESH
    assert result.exit_code == 0


def test_a_sweep_older_than_the_window_is_stale():
    result = verdict([run_at(NOW - timedelta(days=30))], now=NOW, window=WINDOW)
    assert result.state is Freshness.STALE
    assert "30 days" in result.message


def test_no_scheduled_sweep_yet_is_its_own_state_not_a_pass_and_not_a_failure():
    """The schedule was added on 2026-08-14 and first fires the Monday after.
    Reporting that as fresh would be a green light nobody earned, and reporting
    it as stale would cry wolf on every merge until the first run (L36, L98).
    """
    result = verdict([], now=NOW, window=WINDOW)
    assert result.state is Freshness.NOT_YET_RUN
    assert result.exit_code == 0
    assert result.state is not Freshness.FRESH


def test_the_newest_run_decides_not_the_first_one_listed():
    """The API returns runs newest first, but nothing here may depend on that:
    an order assumption that happens to hold makes the check pass for a reason
    unrelated to the rule."""
    runs = [
        run_at(NOW - timedelta(days=40)),
        run_at(NOW - timedelta(days=2)),
        run_at(NOW - timedelta(days=90)),
    ]
    assert verdict(runs, now=NOW, window=WINDOW).state is Freshness.FRESH


def test_a_run_exactly_on_the_window_is_still_fresh():
    """Pinned, because an off by one here decides whether the check fires every
    fortnight for no reason."""
    result = verdict([run_at(NOW - WINDOW)], now=NOW, window=WINDOW)
    assert result.state is Freshness.FRESH


def test_an_unreadable_timestamp_is_not_silently_treated_as_recent():
    """A value that cannot be parsed must never compare as healthy. A failed
    parse that lands on the permissive side of a threshold is a check that
    reports green for the one reason it should not (L50)."""
    result = verdict([{"created_at": "not a date"}], now=NOW, window=WINDOW)
    assert result.state is not Freshness.FRESH
    assert result.exit_code != 0 or result.state is Freshness.UNREADABLE


def test_the_message_names_the_workflow_so_it_can_be_acted_on():
    """A notice naming no target tells the reader something is wrong and gives
    them nowhere to go (L80)."""
    result = verdict([run_at(NOW - timedelta(days=30))], now=NOW, window=WINDOW)
    assert "Guard proofs" in result.message
