"""What a guard entry costs, and the deal made from it (#1090).

`shard_of` used to deal round robin within two cost classes, Swift and Python.
That balanced the COUNT of expensive entries, which is a proxy for cost rather
than a measure of it (L63, L296): measured over ten runs the real per-entry cost
ran from 1,174ms to 106,500ms, a factor of 90, so two Swift entries are not the
same amount of work.

Every refusal here is a refusal rather than a zero, because a zero cost is dealt
as free and a shard that silently carries more than the deal intended reports a
perfectly ordinary green run (L98, L10).
"""

from __future__ import annotations

import json

import pytest

from tools.guard_entry_costs import (
    CostRecordError,
    costs_for,
    deal,
    imbalance,
    read_record,
)


def record_at(path, seconds, measured=None):
    path.write_text(json.dumps({
        "seconds": seconds,
        "measured": measured or {name: {"run": "r", "scale": 1.0}
                                 for name in seconds},
    }))
    return path


# ── the record refuses rather than answering zero ────────────────────────────

def test_a_missing_record_is_refused_by_name(tmp_path):
    with pytest.raises(CostRecordError) as refusal:
        read_record(tmp_path / "nothing.json")
    assert "does not exist" in str(refusal.value)
    assert "record_guard_costs" in str(refusal.value), (
        "the refusal has to name the remedy, or the reader is left with a "
        "message and no action that changes the state they are stuck in (L111)"
    )


def test_an_empty_record_is_refused_rather_than_read_as_free(tmp_path):
    """The failure this whole module exists to make impossible.

    An empty `seconds` map deals every entry at the same cost, which produces a
    partition that looks balanced and is not.
    """
    path = tmp_path / "costs.json"
    path.write_text(json.dumps({"seconds": {}, "measured": {}}))
    with pytest.raises(CostRecordError) as refusal:
        read_record(path)
    assert "deals every entry as free" in str(refusal.value)


def test_an_unreadable_record_says_it_is_unreadable_not_that_it_is_empty(tmp_path):
    """Three failures, three messages: absent, malformed, empty (L11)."""
    path = tmp_path / "costs.json"
    path.write_text("{not json")
    with pytest.raises(CostRecordError) as refusal:
        read_record(path)
    assert "not readable JSON" in str(refusal.value)


# ── an unmeasured entry is estimated from its own kind, never as free ────────

def test_a_measured_entry_keeps_its_reading(tmp_path):
    path = record_at(tmp_path / "costs.json", {"a": 29.0, "b": 0.8})
    costs = costs_for({"a": True, "b": False}, path)
    assert costs.of("a") == 29.0
    assert costs.of("b") == 0.8
    assert costs.estimated == frozenset()
    assert costs.measured == 2


def test_an_unmeasured_swift_entry_takes_the_swift_median_not_the_pooled_one(tmp_path):
    """The 90x error the two kinds make possible.

    A pooled median would price a new Swift entry near a Python one and hand
    whichever shard receives it far more work than the deal intended (L117).
    """
    path = record_at(tmp_path / "costs.json",
                     {"s1": 28.0, "s2": 30.0, "p1": 0.5, "p2": 0.7, "p3": 0.9})
    costs = costs_for({"s1": True, "s2": True, "p1": False, "p2": False,
                       "p3": False, "brand-new": True}, path)
    assert costs.of("brand-new") == 29.0, (
        "a new Swift entry must be priced from the Swift readings, not from a "
        "median pooled across both kinds"
    )
    assert "brand-new" in costs.estimated


def test_an_unmeasured_python_entry_takes_the_python_median(tmp_path):
    path = record_at(tmp_path / "costs.json",
                     {"s1": 28.0, "s2": 30.0, "p1": 0.5, "p2": 0.9})
    costs = costs_for({"s1": True, "s2": True, "p1": False, "p2": False,
                       "brand-new": False}, path)
    assert costs.of("brand-new") == pytest.approx(0.7)


def test_an_entry_of_a_kind_with_no_readings_is_refused(tmp_path):
    """Rather than borrowing the other kind's median, which is the same 90x error."""
    path = record_at(tmp_path / "costs.json", {"p1": 0.5, "p2": 0.9})
    with pytest.raises(CostRecordError) as refusal:
        costs_for({"p1": False, "p2": False, "first-swift": True}, path)
    assert "90x" in str(refusal.value)


def test_a_zero_reading_is_treated_as_no_reading(tmp_path):
    """A guard entry cannot cost nothing.

    A perturbation applies, runs a test and restores a file. A recorded zero is
    a measurement that failed, and reading it as the entry's cost deals it free
    (L331).
    """
    path = record_at(tmp_path / "costs.json", {"a": 29.0, "b": 31.0, "z": 0.0})
    costs = costs_for({"a": True, "b": True, "z": True}, path)
    assert costs.of("z") == 30.0
    assert "z" in costs.estimated


def test_the_measured_count_excludes_the_estimates(tmp_path):
    """Otherwise a deal made entirely of guesses reads as one made of readings."""
    path = record_at(tmp_path / "costs.json", {"a": 29.0, "b": 31.0})
    costs = costs_for({"a": True, "b": True, "c": True, "d": True}, path)
    assert costs.measured == 2
    assert len(costs.estimated) == 2


# ── the deal ─────────────────────────────────────────────────────────────────

def test_every_entry_lands_in_exactly_one_shard():
    """The property the whole split rests on (L98)."""
    names = [f"e{n}" for n in range(37)]
    cost = {name: 1.0 + (index % 7) for index, name in enumerate(names)}
    for total in (1, 2, 3, 6, 11):
        shards = deal(names, total, cost)
        seen = [name for shard in shards for name in shard]
        assert sorted(seen) == sorted(names)
        assert len(seen) == len(set(seen))


def test_the_deal_balances_cost_not_count():
    """The defect being fixed, in one fixture.

    Six entries: one very expensive and five cheap. A deal that balances COUNT
    puts three and three, so one shard carries 30.0 and the other 1.5. A deal
    that balances COST puts the expensive one alone.
    """
    cost = {"big": 30.0, "a": 0.5, "b": 0.5, "c": 0.5, "d": 0.5, "e": 0.5}
    shards = deal(list(cost), 2, cost)
    heavy = next(shard for shard in shards if "big" in shard)
    assert heavy == ["big"], (
        "the expensive entry was dealt alongside cheap ones, so this is still "
        "balancing a count"
    )
    assert sorted(next(s for s in shards if "big" not in s)) == \
        ["a", "b", "c", "d", "e"]


def test_the_deal_beats_the_round_robin_it_replaces():
    """Measured against the old rule in the same fixture, so the claim is not
    merely that the new one is balanced but that it is BETTER (L159)."""
    swift = {f"s{n}": 20.0 + n for n in range(12)}
    python = {f"p{n}": 0.5 for n in range(30)}
    cost = {**swift, **python}
    names = sorted(cost)

    # What shard_of used to do: round robin within each cost class.
    expensive = sorted(swift)
    cheap = sorted(python)
    old = [[e for n, e in enumerate(group) if n % 4 == index]
           for index in range(4) for group in (expensive,)]
    old = [old[index] + [e for n, e in enumerate(cheap) if n % 4 == index]
           for index in range(4)]

    was = imbalance(old, cost)
    now = imbalance(deal(names, 4, cost), cost)
    # Both named, so this cannot pass by the two being equal, which is what a
    # deal that quietly kept the old rule would report (L178).
    assert was == pytest.approx(1.10, abs=0.01), (
        f"the round robin this replaces measured {was:.3f} here, and if that "
        "has changed the comparison below is against something else"
    )
    assert now < 1.01, f"the measured deal came out at {now:.3f}"
    assert now < was


def test_the_deal_is_the_same_every_time():
    """A partition that depends on dictionary order puts an entry on a different
    shard from one run to the next, and the shard that reports what it did NOT
    run would then describe a different set each time."""
    cost = {f"e{n}": float(n % 5) + 1 for n in range(23)}
    first = deal(sorted(cost), 4, cost)
    second = deal(sorted(cost, reverse=True), 4, cost)
    assert first == second


def test_a_split_leaving_a_shard_with_nothing_is_refused():
    """A green run that checked nothing reads exactly like a clean sweep (L98)."""
    with pytest.raises(ValueError) as refusal:
        deal(["only"], 2, {"only": 1.0})
    assert "nothing to prove" in str(refusal.value)


def test_a_zero_way_split_is_refused():
    with pytest.raises(ValueError):
        deal(["a", "b"], 0, {"a": 1.0, "b": 1.0})


# ── the imbalance measure ────────────────────────────────────────────────────

def test_a_perfect_deal_measures_one():
    cost = {"a": 1.0, "b": 1.0, "c": 1.0, "d": 1.0}
    assert imbalance([["a", "b"], ["c", "d"]], cost) == pytest.approx(1.0)


def test_a_lopsided_deal_measures_above_one():
    cost = {"a": 3.0, "b": 1.0}
    assert imbalance([["a"], ["b"]], cost) == pytest.approx(1.5)


def test_shards_that_all_cost_nothing_are_refused_not_called_perfect():
    """0/0 would report a perfect balance of a deal that measured nothing."""
    with pytest.raises(CostRecordError):
        imbalance([["a"], ["b"]], {"a": 0.0, "b": 0.0})
