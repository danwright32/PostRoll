"""#1018: the per-test source walks and file reads are taken once per run.

Audit lesson 30. Several guards sweep the same tree in every one of their
tests, and the read is the cost rather than the check. Measured on 2026-08-30:

    tests/test_swift_tests_never_reach_live_data.py   9.4s  22 tests, six sweeps
    tests/test_guard_mutation_registry.py            20.0s  439 entries, three
                                                            parametrised tests
                                                            each re-reading the
                                                            file the entry names

Both re-read files they have already read, so the memo is on the READ and on
the WALK, keyed by path, and every guard above them is unchanged.

## Why the memo may never hold an empty answer

L286, and it is the whole risk of this change. A memoised empty scan passes
every reader at once: a sweep with nothing in it objects to nothing, so one
failed walk cached at the top of a run would turn every source-scanning guard
in that process green at the same moment, silently and for the rest of the run.

`swift_files` refuses an empty root rather than returning `[]`, and because it
raises, `lru_cache` stores nothing. That is what the first test below pins: the
refusal has to survive being asked twice, or catching it and caching the empty
list would be an easy and invisible thing for a later change to do.

## Why a tuple, not a list

The cached value is handed to every caller, so a list would be one shared
mutable object that any caller could edit under the others.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from source_text import code_of, swift_files, text_of

REPO = Path(__file__).resolve().parent.parent
SWIFT_TESTS = REPO / "PostRollApp" / "Tests"


def test_the_walk_never_memoises_an_empty_scan(tmp_path):
    """The failure this change could introduce, pinned before it can (L286)."""
    with pytest.raises(AssertionError, match="no Swift files"):
        swift_files(tmp_path)

    (tmp_path / "Arrived.swift").write_text("class Arrived {}", encoding="utf-8")

    assert [path.name for path in swift_files(tmp_path)] == ["Arrived.swift"], (
        "the refusal was cached, so a root that was empty once reads as empty "
        "for the rest of the run and every sweep over it passes at once")


def test_the_walk_really_is_taken_only_once():
    """Otherwise this bought nothing and nothing would say so (L289)."""
    swift_files.cache_clear()
    first = swift_files(SWIFT_TESTS)
    second = swift_files(SWIFT_TESTS)
    assert swift_files.cache_info().hits == 1, (
        "the second walk was taken again, so the memo is not being used and "
        "the cost this change exists to remove is still being paid")
    assert first is second


def test_the_walk_finds_the_real_swift_tests():
    """A memo over a walk that finds nothing real proves nothing (L98)."""
    found = swift_files(SWIFT_TESTS)
    assert len(found) > 50, f"only {len(found)} Swift test files were found"
    assert all(path.suffix == ".swift" for path in found)


def test_the_cached_walk_cannot_be_edited_by_one_caller():
    assert isinstance(swift_files(SWIFT_TESTS), tuple), (
        "the walk hands every caller the same object, so a list would let one "
        "of them reorder or empty it under the others")


def test_the_text_is_what_the_file_holds(tmp_path):
    written = tmp_path / "Thing.swift"
    written.write_text("class Thing {}\n", encoding="utf-8")
    assert text_of(written) == "class Thing {}\n"


def test_the_text_is_read_only_once():
    text_of.cache_clear()
    path = SWIFT_TESTS / sorted(p.name for p in swift_files(SWIFT_TESTS))[0]
    text_of(path)
    text_of(path)
    assert text_of.cache_info().hits == 1


def test_the_code_only_form_still_strips_comments(tmp_path):
    """The memo sits on top of `swift_code_only`; it must not change it."""
    written = tmp_path / "Commented.swift"
    written.write_text('// AnalyticsStore()\nlet real = 1\n', encoding="utf-8")
    assert "AnalyticsStore()" not in code_of(written)
    assert "let real = 1" in code_of(written)


def test_the_code_only_form_is_computed_once():
    code_of.cache_clear()
    path = sorted(swift_files(SWIFT_TESTS))[0]
    code_of(path)
    code_of(path)
    assert code_of.cache_info().hits == 1
