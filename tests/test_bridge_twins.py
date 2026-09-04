"""#1106: the twin list is derived, not read off a comment.

Every pair that must agree across the bridge used to be found by a HUMAN
noticing one. The evidence that a pair was covered was a `Mirrors ...` line in a
docstring, and every declared pair was in fact pinned by a shared fixture. The
gap was that the declaration is voluntary: a twin whose author never wrote the
comment was invisible to any sweep built on it, which is a guard checking only
what its own hand written registry names (L96, L217).

`is_real_handle` and `isRealHandle` were exactly that. Same question, same name,
two answers, no fixture, and they were found because somebody read both by
chance. What made that one findable is derivable, so it is derived.

## What this cannot see

A twin whose two halves are NAMED DIFFERENTLY. That is said plainly rather than
implied: this finds pairs by name, and a Python `handle_ok` beside a Swift
`isValidHandle` is invisible to it. The `Mirrors ...` comments stay useful for
exactly that case, and this covers the case they cannot be relied on for, which
is somebody not writing one.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from bridge_twins import (  # noqa: E402
    EXCLUSIONS, camel, contracts, excluded, python_functions, swift_functions,
    twins)


def test_every_twin_is_pinned_or_excused():
    """One assertion rather than one per pair, so the zero case is a PASS
    rather than an empty parameter set pytest reports as a skip (L98)."""
    reasons = excluded()
    loose = [f"{t['python']} ({t['python_files'][0]}) <-> "
             f"{t['swift']} ({t['swift_files'][0]})"
             for t in twins()
             if not t["pinned_by"] and t["python"] not in reasons]

    assert not loose, (
        "these are the same name on both sides of the bridge with nothing "
        "holding the two answers together, so they can drift apart "
        "indefinitely while every check on each side passes (#1106):\n"
        + "\n".join(loose)
        + f"\n\nEither pin the pair with a shared fixture under "
          f"tests/fixtures/ that BOTH suites read, or add the Python name to "
          f"{EXCLUSIONS.name} with the reason it is not a twin.")


def test_the_sweep_finds_the_pairs_that_are_really_there():
    """The positive control. A sweep matching nothing reports a repository with
    no twins, and every twin in an empty list is pinned (L98, L100)."""
    found = twins()
    names = {t["python"] for t in found}

    assert len(found) >= 15, f"only {len(found)} candidate pairs were found"
    for known in ("is_real_handle", "is_handle_shaped", "layout_problems",
                  "seo_description", "week_tags"):
        assert known in names, (
            f"{known} is a twin this repository really has and the sweep did "
            f"not find it, so the sweep has stopped reading one of the halves")


def test_the_sweep_reads_both_halves():
    """Either half coming back empty would report no pairs at all, and the
    check above would pass on nothing (L178: two conditions over one body are
    satisfied by two unrelated places in it)."""
    assert len(python_functions()) > 200, "the Python half found almost nothing"
    assert len(swift_functions()) > 200, "the Swift half found almost nothing"
    assert len(contracts()) > 10, "no shared fixtures were found, so every "\
                                  "pair would report as unpinned"


def test_a_caller_into_python_is_not_read_as_a_twin():
    """The narrowing that keeps this readable, asserted rather than assumed.

    An `async` Swift member is a CALLER: it packs some JSON and waits for a
    subprocess. A twin re-implements a pure rule and has nothing to await. This
    is what separates `PythonBridge.suggestHandles` from
    `PythonBridge.isRealHandle`, which live in the same file, so a rule that
    excluded the file would lose the twin the whole issue is about (L104)."""
    swift = swift_functions()

    assert "isRealHandle" in swift, (
        "the twin this issue was filed about is no longer read as one")
    assert "suggestHandles" not in swift, (
        "an async bridge call is being read as a twin, which would demand a "
        "shared fixture for a function that only forwards to Python")


def test_a_single_word_name_is_not_read_as_a_pair():
    """The other narrowing. Measured 2026-09-04: 86 candidates without it, 33
    with it, and the 53 it removed contained no real twin, only collisions like
    `add`, `at`, `fetch` and `finish` (L104)."""
    assert not [t for t in twins() if "_" not in t["python"]], (
        "a single word name is being paired, and those collide constantly")


def test_the_name_mapping_is_the_one_the_pairs_rest_on():
    """The reading that decides every check above, asserted directly rather
    than only through them (L178)."""
    assert camel("is_real_handle") == "isRealHandle"
    assert camel("week_tags") == "weekTags"
    assert camel("post_type") == "postType"


def test_every_exclusion_still_names_a_pair_that_exists():
    """A stale entry excuses a real failure silently, and it is invisible
    because the entry still reads as a considered decision (L217, L233)."""
    present = {t["python"] for t in twins()}
    stale = sorted(name for name in excluded() if name not in present)

    assert not stale, (
        f"these exclusions name no candidate pair any more: {stale}. Either "
        f"one half was renamed or removed, and the entry now excuses nothing "
        f"while looking like it does")


def test_every_exclusion_carries_a_reason():
    """An entry with no reason is evidence nobody reasoned about it (L233)."""
    thin = {name: why for name, why in excluded().items() if len(why.split()) < 15}

    assert not thin, (
        f"these exclusions say too little to be a reason: {list(thin)}. Say "
        f"what each half actually does, not that the pair is fine")


def test_a_tooling_record_does_not_count_as_a_contract():
    """A guard mutation entry names the function it perturbs, and the durations
    record names every test file. Counting either as a shared fixture would
    report a twin as pinned by a file that asserts nothing about the two halves
    agreeing (L103)."""
    assert "test_file_durations.json" not in contracts()
    assert not [name for name in contracts() if "mutation" in name]
    assert json.loads(EXCLUSIONS.read_text(encoding="utf-8")), (
        "the exclusions file is unreadable or empty, and every check above "
        "reads it")
