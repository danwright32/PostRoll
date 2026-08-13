"""The guard that keeps the suite safe to run in parallel (#497).

`tests/conftest.py` fails any module that writes into `postroll/`. That guard is a
fixture rather than a test, so its comparison is exercised here: a check whose own
mechanism has never been seen working is indistinguishable from one that passes
because it compares nothing (L1).

It earned itself on the day it landed. Run against the suite as it then was, it
named `brand_text.py`, `generate_reel_morph.py` and `program_plate.py`, which the
design fingerprint guards were rewriting in place and restoring, and which made
`pytest tests/ -n auto` report a template redesign that never happened.
"""

from __future__ import annotations

from pathlib import Path

from conftest import source_tree_changes, _source_tree_state


def test_an_unchanged_tree_reports_nothing():
    snapshot = {"/a/one.py": (10, 100), "/a/two.py": (20, 200)}

    assert source_tree_changes(snapshot, dict(snapshot)) == []


def test_a_rewritten_file_is_named_even_when_its_size_is_unchanged():
    """The case that matters. A perturbation that swaps one digit for another,
    then puts the original back, leaves the size identical and the timestamp
    moved, so a size-only comparison would miss every write this guard is for."""
    before = {"/a/program_plate.py": (10, 100)}
    after = {"/a/program_plate.py": (11, 100)}

    assert source_tree_changes(before, after) == ["program_plate.py"]


def test_an_added_or_removed_file_is_named_too():
    assert source_tree_changes({}, {"/a/new.py": (1, 1)}) == ["new.py"]
    assert source_tree_changes({"/a/gone.py": (1, 1)}, {}) == ["gone.py"]


def test_the_snapshot_actually_covers_the_source_tree():
    """If this found nothing, the guard would be watching an empty set and every
    module would pass it for want of anything to compare."""
    state = _source_tree_state()

    assert len(state) > 20, f"only {len(state)} source files snapshotted"
    assert any(Path(name).name == "design_fingerprint.py" for name in state), (
        "the module whose files were being rewritten is not even being watched")
