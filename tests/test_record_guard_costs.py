"""Folding a sweep's readings into the cost record (#1090).

Every refusal here is a refusal rather than a partial write. The record decides
how the sweep is dealt and how the largest shard is projected against its
deadline, so a record built from two different sweeps, or from a run that
measured nothing, is worse than no record at all: it deals confidently on
numbers that describe neither run (L224, L98).
"""

from __future__ import annotations

import json

import pytest

from tools.record_guard_costs import (
    _refuse_a_partial_sweep, readings_of, main)


def readings(tmp_path, name, run, seconds, kinds=None, cold=None, shard="1/1"):
    path = tmp_path / name
    path.write_text(json.dumps({
        "run": run, "seconds": seconds, "measured_on": "2026-08-31",
        "kinds": kinds if kinds is not None else {n: True for n in seconds},
        "cold": cold, "shard": shard,
    }))
    return path


def whole_sweep(tmp_path, width=6, run="run-7"):
    """Every shard of one sweep, which is what the record replaces itself from.

    The default above is `1/1`, a sweep split one way, because every fixture
    here that is not about shard completeness means "a whole sweep" and said it
    as `1/6`, which #1344 made a partial one.
    """
    return [readings(tmp_path, f"s{n}.json", run, {f"entry-{n}": 1.0 + n},
                     shard=f"{n}/{width}")
            for n in range(1, width + 1)]


def test_the_shards_of_one_sweep_are_one_set(tmp_path):
    a = readings(tmp_path, "s1.json", "run-7", {"one": 29.0})
    b = readings(tmp_path, "s2.json", "run-7", {"two": 0.8})
    seconds, kinds, _, run = readings_of([a, b])
    assert seconds == {"one": 29.0, "two": 0.8}
    assert kinds == {"one": True, "two": True}
    assert run == "run-7"


def test_a_sweep_missing_a_shard_is_refused_rather_than_recorded(tmp_path):
    """The defect #1344 introduced, caught before it merged.

    The record REPLACES itself from one sweep, on the stated grounds that a
    whole sweep IS the registry and an entry it does not hold is one the
    registry no longer has. #1344 made a sweep able to run only the shards that
    have something to prove, so a run where one shard was due now uploads one
    artifact. Replacing the record from it would price the whole registry from
    a seventh of it, silently: every reading in that file is correct, there are
    simply far fewer of them, which is why nothing in the contents would say so.

    What depends on the record makes it worse than noise. `shard_of` deals
    entries into shards BY measured cost, and
    tests/test_guard_sweep_fits_its_deadline.py projects the largest shard
    against its deadline from the same numbers. Both would be confidently
    wrong, and the sweep would go on reporting success (L288, L331, L98).
    """
    partial = [readings(tmp_path, "s3.json", "run-7", {"one": 29.0}, shard="3/7")]

    with pytest.raises(SystemExit, match="shard"):
        _refuse_a_partial_sweep(partial)


def test_the_shards_that_are_missing_are_named(tmp_path):
    """A refusal that does not say WHICH shards are absent leaves the reader
    knowing something is wrong and with nowhere to go (L80)."""
    present = [readings(tmp_path, "s1.json", "run-7", {"one": 1.0}, shard="1/4"),
               readings(tmp_path, "s3.json", "run-7", {"two": 2.0}, shard="3/4")]

    with pytest.raises(SystemExit) as refused:
        _refuse_a_partial_sweep(present)

    assert "2" in str(refused.value) and "4" in str(refused.value), (
        f"the refusal does not name the missing shards: {refused.value}")


def test_shards_disagreeing_about_the_width_are_refused(tmp_path):
    """Two artifacts from sweeps split different ways are not one sweep, and
    the completeness check above would be measuring nothing if they were let
    through: it would count two of two and be satisfied."""
    mixed = [readings(tmp_path, "s1.json", "run-7", {"one": 1.0}, shard="1/2"),
             readings(tmp_path, "s2.json", "run-7", {"two": 2.0}, shard="2/9")]

    with pytest.raises(SystemExit, match="split"):
        _refuse_a_partial_sweep(mixed)


def test_a_whole_sweep_is_still_accepted(tmp_path):
    """The control. A completeness check that refused everything would also
    make every test above pass (L159)."""
    whole = whole_sweep(tmp_path)

    _refuse_a_partial_sweep(whole)          # does not raise
    seconds, _, _, run = readings_of(whole)

    assert len(seconds) == 6
    assert run == "run-7"


def test_readings_from_two_different_runs_are_refused(tmp_path):
    """The defect this refusal exists for.

    Two sweeps under different load averaged into one record produce a number
    that describes neither, and the record says nothing about it.
    """
    a = readings(tmp_path, "s1.json", "run-7", {"one": 29.0})
    b = readings(tmp_path, "s2.json", "run-9", {"two": 0.8})
    with pytest.raises(SystemExit) as refusal:
        readings_of([a, b])
    assert "2 different runs" in str(refusal.value)
    assert "Nothing was written" in str(refusal.value)


def test_an_entry_measured_twice_is_refused(tmp_path):
    """Every entry lands in exactly one shard, so two readings mean these are
    not the shards of one sweep."""
    a = readings(tmp_path, "s1.json", "run-7", {"one": 29.0})
    b = readings(tmp_path, "s2.json", "run-7", {"one": 31.0})
    with pytest.raises(SystemExit) as refusal:
        readings_of([a, b])
    assert "more than one" in str(refusal.value)


def test_an_empty_readings_file_is_refused(tmp_path):
    a = readings(tmp_path, "s1.json", "run-7", {})
    with pytest.raises(SystemExit) as refusal:
        readings_of([a])
    assert "deals every entry as free" in str(refusal.value)


def test_a_zero_reading_is_refused(tmp_path):
    """A perturbation applies, runs a test and restores a file. Zero is a
    measurement that failed, and dealing it as free is the whole defect (L331)."""
    a = readings(tmp_path, "s1.json", "run-7", {"one": 0.0})
    with pytest.raises(SystemExit) as refusal:
        readings_of([a])
    assert "cannot be right" in str(refusal.value)


def test_a_missing_readings_file_is_refused_by_name(tmp_path):
    with pytest.raises(SystemExit) as refusal:
        readings_of([tmp_path / "gone.json"])
    assert "does not exist" in str(refusal.value)


# ── writing ──────────────────────────────────────────────────────────────────

def test_a_whole_sweep_replaces_the_record_and_stamps_every_reading(tmp_path):
    a = readings(tmp_path, "s1.json", "run-7", {"one": 29.0, "two": 0.8})
    record = tmp_path / "costs.json"
    record.write_text(json.dumps({"seconds": {"old": 5.0},
                                  "measured": {"old": {"run": "r", "scale": 1.0}}}))

    assert main(["--from", str(a), "--record", str(record)]) == 0

    written = json.loads(record.read_text())
    assert written["seconds"] == {"one": 29.0, "two": 0.8}, (
        "a whole sweep replaces the record; an entry the sweep no longer holds "
        "is one the registry no longer has"
    )
    assert all(stamp["run"] == "run-7" for stamp in written["measured"].values())
    assert all(stamp["scale"] == 1.0 for stamp in written["measured"].values()), (
        "every reading came from one sweep, so nothing needed scaling"
    )


def test_adding_a_later_run_scales_it_onto_the_record(tmp_path):
    """The entries already in the record KEEP their readings.

    Re-writing them from a different run is the churn #1038 exists to avoid,
    and it would move the deal for entries nobody changed.
    """
    record = tmp_path / "costs.json"
    record.write_text(json.dumps({
        "seconds": {"a": 30.0, "b": 20.0},
        "measured": {name: {"run": "run-7", "scale": 1.0} for name in ("a", "b")},
    }))
    # This run was half the speed: a measured 60, b measured 40, so the scale
    # onto the record's run is 0.5.
    later = readings(tmp_path, "later.json", "run-9",
                     {"a": 60.0, "b": 40.0, "c": 10.0})

    assert main(["--add", str(later), "--record", str(record)]) == 0

    written = json.loads(record.read_text())
    assert written["seconds"]["a"] == 30.0
    assert written["seconds"]["b"] == 20.0
    assert written["seconds"]["c"] == 5.0, (
        "the new entry was written at this run's raw reading rather than "
        "scaled onto the record's own run"
    )
    assert written["measured"]["c"] == {"run": "run-9", "scale": 0.5}


def test_saying_neither_mode_is_refused():
    with pytest.raises(SystemExit):
        main([])


def test_saying_two_modes_is_refused(tmp_path):
    a = readings(tmp_path, "s1.json", "run-7", {"one": 1.0})
    with pytest.raises(SystemExit):
        main(["--from", str(a), "--add", str(a)])


# ── a reading is only valid for the kind it was taken as (#1089, L133) ───────

def test_a_reading_taken_as_swift_is_dropped_once_the_entry_is_python(tmp_path):
    """#1089 moved seven entries from a Swift test to a Python one.

    Their recorded 29s went on describing something that now costs 0.2s, and a
    bare name-to-seconds map cannot tell that from an entry that got slower.
    """
    from tools.guard_entry_costs import costs_for

    record = tmp_path / "costs.json"
    record.write_text(json.dumps({
        "seconds": {"moved": 29.0, "p1": 0.6, "p2": 1.0},
        "kinds": {"moved": True, "p1": False, "p2": False},
        "measured": {n: {"run": "r", "scale": 1.0}
                     for n in ("moved", "p1", "p2")},
    }))

    costs = costs_for({"moved": False, "p1": False, "p2": False}, record)
    assert costs.of("moved") == pytest.approx(0.8), (
        "the stale Swift reading was kept for an entry that is now proved by "
        "pytest, so it is dealt at about 90 times what it costs"
    )
    assert "moved" in costs.estimated


def test_a_reading_whose_kind_still_matches_is_kept(tmp_path):
    """The positive control, in the same fixture as the refusal (L159)."""
    from tools.guard_entry_costs import costs_for

    record = tmp_path / "costs.json"
    record.write_text(json.dumps({
        "seconds": {"stayed": 29.0, "p1": 0.6},
        "kinds": {"stayed": True, "p1": False},
        "measured": {n: {"run": "r", "scale": 1.0} for n in ("stayed", "p1")},
    }))

    costs = costs_for({"stayed": True, "p1": False}, record)
    assert costs.of("stayed") == 29.0
    assert costs.estimated == frozenset()


def test_a_record_with_no_kinds_at_all_keeps_every_reading(tmp_path):
    """A record written before kinds were recorded is not thereby empty.

    Discarding every reading for want of a stamp would empty the record, and an
    empty record deals every entry as free (L98).
    """
    from tools.guard_entry_costs import costs_for

    record = tmp_path / "costs.json"
    record.write_text(json.dumps({
        "seconds": {"a": 29.0, "b": 0.6},
        "measured": {n: {"run": "r", "scale": 1.0} for n in ("a", "b")},
    }))

    costs = costs_for({"a": True, "b": False}, record)
    assert costs.of("a") == 29.0
    assert costs.of("b") == 0.6
    assert costs.estimated == frozenset()


def test_a_shard_that_ran_out_of_time_is_refused(tmp_path):
    """The one way a readings file can be WRONG while every number in it is right.

    A shard that hit its deadline measured the entries it reached and nothing
    about the ones it did not. Its file holds correct readings, there are simply
    fewer of them, so nothing in the contents would say so and the missing
    entries would be silently estimated (L331).
    """
    path = tmp_path / "short.json"
    path.write_text(json.dumps({
        "run": "run-7", "seconds": {"one": 29.0}, "measured_on": "2026-08-31",
        "kinds": {"one": True}, "unproven": ["two", "three"],
    }))
    with pytest.raises(SystemExit) as refusal:
        readings_of([path])
    assert "ran out of time" in str(refusal.value)
    assert "2 entries never reached" in str(refusal.value)
    assert "Nothing was written" in str(refusal.value)


def test_a_shard_that_reached_everything_is_accepted(tmp_path):
    """The positive control, in the same fixture, so the refusal above cannot be
    what every file gets (L159)."""
    path = tmp_path / "whole.json"
    path.write_text(json.dumps({
        "run": "run-7", "seconds": {"one": 29.0}, "measured_on": "2026-08-31",
        "kinds": {"one": True}, "unproven": [],
    }))
    seconds, kinds, _, run = readings_of([path])
    assert seconds == {"one": 29.0}


def test_a_file_written_before_the_field_existed_is_accepted(tmp_path):
    """An absent `unproven` is not an empty one, but refusing on it would make
    every older readings file unusable, and absent is what a complete sweep
    looked like before this was recorded."""
    path = tmp_path / "old.json"
    path.write_text(json.dumps({
        "run": "run-7", "seconds": {"one": 29.0}, "kinds": {"one": True},
    }))
    seconds, _, _, _ = readings_of([path])
    assert seconds == {"one": 29.0}


def test_the_cold_build_reading_is_carried_into_the_record(tmp_path):
    """`write_timings` sets the first Swift entry's reading aside so it is not
    read as that entry's cost, and the reason given for keeping it at all is
    that it is the only measurement anyone has of what the app build costs.

    An artifact expires. A reading that stopped there would make that reason
    false in the one place it matters (L46, L202).
    """
    a = readings(tmp_path, "s1.json", "run-7", {"one": 29.0},
                 cold={"entry": "first-swift", "seconds": 121.4})
    record = tmp_path / "costs.json"

    assert main(["--from", str(a), "--record", str(record)]) == 0

    written = json.loads(record.read_text())
    assert written["cold"] == [
        {"entry": "first-swift", "seconds": 121.4, "shard": "1/1"}]
    assert "first-swift" not in written["seconds"], (
        "the cold reading was carried through AND recorded as a cost, which is "
        "the mispricing it exists to avoid")


def test_a_sweep_with_no_cold_reading_records_an_empty_list(tmp_path):
    """A shard of nothing but Python entries never built the app. Empty is the
    right answer and must not read as a missing field."""
    a = readings(tmp_path, "s1.json", "run-7", {"one": 0.5}, cold=None)
    record = tmp_path / "costs.json"
    main(["--from", str(a), "--record", str(record)])
    assert json.loads(record.read_text())["cold"] == []
