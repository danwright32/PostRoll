"""#1127: what the repair pass's timeout is derived from, and what it is not.

Dan's decision, 2026-08-31: spend one real image-carrying call, record the
number with its date, and derive the per-call timeout and the round budget from
it. Three were spent, on 2026-09-01.

No image-carrying call had ever been timed in this project. The plan's 300
seconds was cloned from `swap_blog_photos.py`, the only image-carrying call in
the repo, whose 300 was itself never measured. At that figure seven markers at
two rounds is 4,200 seconds against an 1,800 second process ceiling, so the plan
concluded the round cap would have to drop to one round per target and the
repair would be weaker for a number nobody had measured.

Measured, a call takes about three seconds. Seven markers at two rounds is under
a minute, so the cap does not have to move and the deadline is not tight.

These tests read the RECORD rather than making calls. The measurement costs
money and reaches the live API, which the suite may never do (L2).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.measure_alt_text_call import RECORD, _TIMEOUT_FLOOR, summarise


def _record() -> dict:
    return json.loads(RECORD.read_text(encoding="utf-8"))


def test_the_measurement_exists_and_says_when_it_was_taken():
    assert RECORD.exists(), (
        "no timing has been recorded, so every number the repair pass derives "
        "from it is a guess. Run tools/measure_alt_text_call.py --photo <a real "
        "photograph>.")
    readings = _record()["readings"]
    assert readings, "the record holds no readings, which is not a fast call (L98)"
    for reading in readings:
        assert reading["measured_on"], reading
        assert reading["seconds"] > 0, reading


def test_more_than_one_reading_was_taken():
    """One reading is a sample of one and cannot show a spread."""
    assert len(_record()["readings"]) >= 3, (
        "fewer than three readings, so nothing here can tell a typical call "
        "from a lucky one")


def test_the_readings_carry_the_photograph_size_they_were_taken_with():
    """An image call's cost could plausibly scale with the file, and the record
    has to be able to answer that rather than leave it assumed."""
    sizes = [r["photo_bytes"] for r in _record()["readings"]]
    assert min(sizes) * 2 < max(sizes), (
        f"every reading used a similarly sized photograph ({sizes}), so the "
        "record cannot say whether the cost scales with the file at all")


def test_only_a_call_that_ANSWERED_counts_toward_the_cost():
    """A call that returned nothing timed the failure, not the work.

    Averaging it in reports a broken run as a fast one, and a number written
    into a store that later DECIDES something must record whether the run it
    came from did the work (L331).
    """
    real = [{"seconds": 4.0, "answered": True},
            {"seconds": 0.2, "answered": False}]
    assert summarise(real)["fastest"] == 4.0


def test_an_empty_record_summarises_to_nothing_rather_than_to_zero():
    assert summarise([]) == {}, "an unmeasured record must not read as a fast one"


def test_the_recommended_timeout_never_drops_below_the_floor():
    """The harm is asymmetric, and this is why the recommendation is not just a
    multiple of the slowest reading.

    Too LOW cuts a call that DID start and reports it as `blocked`, telling Dan
    the app could not reach the model on a rewrite it had begun, which is the
    claim L11 forbids. Too HIGH costs only that a dead call is noticed later,
    and the pass has a wall clock deadline regardless.
    """
    assert summarise([{"seconds": 0.1, "answered": True}])["recommended_timeout"] \
        == _TIMEOUT_FLOOR


def test_a_slow_measurement_raises_the_recommendation_above_the_floor():
    """The control: the floor must not make the measurement irrelevant (L159)."""
    slow = summarise([{"seconds": 300.0, "answered": True}])
    assert slow["recommended_timeout"] > _TIMEOUT_FLOOR


def test_the_round_budget_is_reported_in_the_same_place_as_the_cost():
    """The number the plan got wrong, kept beside the number it comes from.

    The plan's 300 seconds made seven markers at two rounds 4,200 seconds and
    concluded the round cap had to drop to one. This states the real figure so
    the next person re-reads a measurement rather than an argument (L316).
    """
    summary = summarise(_record()["readings"])
    assert summary["seven_markers_two_rounds"] == pytest.approx(
        summary["slowest"] * 14, rel=0.01)


def test_the_measured_budget_leaves_the_round_cap_where_the_plan_wanted_it():
    """If this ever goes red, the round cap is the number to change, not the
    timeout: at a high enough per-call cost, two rounds per target cannot fit
    under the process ceiling and the pass would be killed mid-run, destroying
    every paid call in the whole week."""
    summary = summarise(_record()["readings"])
    # PythonBridge.processTimeout is 1800s and the week run spends most of it on
    # captions before the blog starts, so the repair pass gets a fraction.
    assert summary["seven_markers_two_rounds"] < 300, (
        f"seven markers at two rounds now costs "
        f"{summary['seven_markers_two_rounds']}s, which is no longer a rounding "
        "error against the process ceiling. Re-derive the round cap.")
