"""Two paths that produce one payload shape are compared to each other (#1023).

`generate_captions.generate_caption` and `revise_caption.revise_caption` both
produce a day caption. `generate_blog` and `revise_blog` both produce a blog.
Each was checked against its OWN contract entry and never against its sibling,
so a key carried by one and dropped by the other was invisible at both ends:
neither reader can tell a revision that lost a field from a caption that never
had one, and the failing behaviour reads as normal.

That is not hypothetical. #1008 added `alt_text_photo_paths` to the generation
path and the revision silently dropped it; the only reason it was caught is that
Swift happened to READ the key, so the contract noticed a reader for something
undeclared. Had Swift not read it, the two would have disagreed indefinitely
(L263: a shared NAME is read as evidence of shared BEHAVIOUR, so two paths
either side of one shape are never compared).

## Differences are allowed, but each one has to be argued

`day_caption` carries `skipped_photos` and `revised_caption` does not, and that
is correct: the key comes from deciding which photographs are too large to
upload, which happens when photos are STAGED. A revision works from an existing
caption and stages nothing, so it has nothing to skip.

So the contract declares those exceptions with a reason each, and this file
holds them to being real. An exception that has stopped applying is worse than
no exception, because it reads as a decision somebody made while exempting a
key nobody is looking at any more (L233, L336).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tests.test_bridge_payload_contract import (
    CONTRACT_PATH, PAYLOADS, emitted_keys, keys_per_producer)

CONTRACT = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))

#: The groups, without the file's own prose. A leading underscore is how this
#: contract marks a key that documents rather than declares, and reading `_what`
#: as a group made three checks fail about a paragraph.
SIBLINGS = {name: spec for name, spec in CONTRACT.get("_siblings", {}).items()
            if not name.startswith("_")}


def divergence(keys_by_payload: dict[str, set[str]],
               missing_in: dict[str, dict]) -> dict[str, set[str]]:
    """Keys that one payload in a group emits and another does not.

    `missing_in` names, per key, the payload that legitimately LACKS it and
    why. It used to name the one that HAS it, which says the same thing while a
    group holds exactly two payloads and stops being expressible the moment one
    holds three: the blog group has three producers since #1357 and `title`
    is absent from one of them rather than present in only one (L324, the
    stand down no broader than the reason for it).

    Pure, so the tests below can drive it with a shape they invent as well as
    with the real contract: the real one is expected to be clean, and a check
    that has only ever been run on clean input has never been seen to fail (L1).
    """
    everywhere = set().union(*keys_by_payload.values()) if keys_by_payload else set()
    missing = {}
    for name, keys in keys_by_payload.items():
        excused = {key for key, spec in missing_in.items()
                   if spec.get("payload") == name}
        gap = {k for k in everywhere - keys if k not in excused}
        if gap:
            missing[name] = gap
    return missing


#: Two entries whose declared keys overlap this much or more are the same shape
#: produced twice until somebody says otherwise (#1357).
#:
#: Measured across all 561 pairs on 2026-09-05, as the share of the two key sets
#: that is common to both: the median pair shares NOTHING, 554 of 561 share less
#: than 0.29, and the seven above that run 0.667, 0.75, 0.857, 0.857, 0.875 and
#: 1.0 twice. So there is a wide empty band between 0.286 and 0.667 and this
#: sits in it, rather than inside the dense middle where a small shift carries
#: many pairs across at once and the count turns into noise (L172).
OVERLAP = 0.5

#: Pairs above that line which are NOT one shape produced twice, each with the
#: reason. Read off the contract rather than listed here, so the argument sits
#: beside the payloads it is about.
UNRELATED = {frozenset(pair["payloads"]): pair
             for pair in CONTRACT.get("_unrelated", {}).get("pairs", [])}


def overlap(one: set[str], other: set[str]) -> float:
    """The share of the two key sets that both carry.

    Zero when either is empty: an entry declaring no keys cannot be evidence
    that it is the same shape as anything.
    """
    if not one or not other:
        return 0.0
    return len(one & other) / len(one | other)


def looks_like_one_shape() -> list[tuple[str, str, float]]:
    """Every pair of entries whose keys overlap at or above the line."""
    names = sorted(PAYLOADS)
    found = []
    for i, one in enumerate(names):
        for other in names[i + 1:]:
            share = overlap(emitted_keys(PAYLOADS[one]),
                            emitted_keys(PAYLOADS[other]))
            if share >= OVERLAP:
                found.append((one, other, round(share, 3)))
    return found


# ── a shape that gained a second producer (#1357) ────────────────────────────


def test_the_overlap_sweep_finds_something_to_judge():
    """The positive control. A sweep matching nothing would report every pair as
    accounted for, which is what the hand-written list already did (L98)."""
    assert looks_like_one_shape(), (
        "no pair of payload entries overlaps at all, so the check below passes "
        "over an empty set")


def test_every_pair_that_looks_like_one_shape_is_grouped_or_argued():
    """A hand-written list of sibling groups checks only what the list names,
    and the entry missing from it is exempt from the very check meant to catch
    it (L96, #1357). Two entries that are one shape produced twice have heavily
    overlapping keys; two unrelated payloads share almost nothing."""
    grouped = {frozenset(spec["payloads"]) for spec in SIBLINGS.values()}
    unaccounted = []
    for one, other, share in looks_like_one_shape():
        pair = frozenset((one, other))
        if any(pair <= group for group in grouped) or pair in UNRELATED:
            continue
        unaccounted.append(f"{one} / {other} share {share}")

    assert not unaccounted, (
        "these payload entries declare nearly the same keys and nothing says "
        "whether they are one shape produced twice:\n  "
        + "\n  ".join(unaccounted)
        + "\nEither put them in a `_siblings` group, where their producers are "
          "compared key by key, or declare the pair under `_unrelated` with the "
          "reason they are not the same thing.")


def test_every_pair_declared_unrelated_is_one_this_would_have_flagged():
    """A declaration for a pair nothing flags is covering nothing, and it reads
    as a decision somebody made (L346, L233)."""
    flagged = {frozenset((one, other)) for one, other, _ in looks_like_one_shape()}
    for pair, spec in UNRELATED.items():
        assert pair <= set(PAYLOADS), (
            f"{sorted(pair)} names a payload the contract does not declare")
        assert pair in flagged, (
            f"{sorted(pair)} is declared unrelated, but their keys no longer "
            f"overlap enough for anything to have asked. The declaration is "
            f"covering nothing.")
        assert (spec.get("why") or "").strip(), (
            f"{sorted(pair)} is declared unrelated with no reason, so nobody "
            f"can tell a considered difference from an oversight")


def test_a_pair_that_shares_almost_nothing_is_not_flagged():
    """The other direction, on sets this test controls: the line has to leave
    ordinary unrelated payloads alone or the declaration list becomes the
    contract (L172)."""
    assert overlap({"body", "title"}, {"errors", "warnings"}) == 0.0
    assert overlap({"a", "b", "c", "d"}, {"a", "e", "f", "g"}) < OVERLAP


def test_two_producers_of_one_shape_are_flagged():
    """The signature, on sets this test controls."""
    assert overlap({"body", "findings", "title"},
                   {"body", "findings", "title"}) == 1.0
    assert overlap({"body", "findings", "findings_body", "title"},
                   {"body", "findings", "findings_body"}) >= OVERLAP


# ── the sweep finds something ────────────────────────────────────────────────


def test_the_contract_declares_which_shapes_have_more_than_one_producer():
    """The positive control. With no groups declared every check below passes
    over an empty set, which is exactly the state this file exists to end
    (L98, L100)."""
    assert SIBLINGS, (
        "the contract declares no sibling groups, so nothing compares the two "
        "paths that produce a day caption, or the two that produce a blog")
    for group, spec in SIBLINGS.items():
        assert len(spec.get("payloads", [])) >= 2, (
            f"the {group!r} group names fewer than two payloads, so it has no "
            f"sibling to be compared against")
        for name in spec["payloads"]:
            assert name in PAYLOADS, (
                f"the {group!r} group names {name!r}, which the contract does "
                f"not declare, so this group checks less than it appears to")


def test_the_two_paths_that_produce_a_day_caption_are_a_group():
    """Named rather than derived, because the group is the CLAIM: these two are
    meant to be interchangeable to a reader. Deriving it from, say, a shared
    key would make the check agree with whatever the code currently does."""
    grouped = {name for spec in SIBLINGS.values() for name in spec["payloads"]}

    for expected in ("day_caption", "revised_caption", "blog_output",
                     "revised_blog"):
        assert expected in grouped, (
            f"{expected} is in no sibling group, so nothing compares it with "
            f"the other path that produces the same shape")


# ── the real contract ────────────────────────────────────────────────────────


@pytest.mark.parametrize("group", sorted(SIBLINGS))
def test_every_producer_of_one_shape_emits_the_same_keys(group):
    spec = SIBLINGS[group]
    keys_by_payload = {name: emitted_keys(PAYLOADS[name])
                       for name in spec["payloads"]}

    gaps = divergence(keys_by_payload, spec.get("missing_in") or {})

    assert not gaps, (
        f"in the {group!r} group, these producers are missing keys their "
        f"sibling emits: "
        + "; ".join(f"{name} lacks {sorted(missing)}"
                    for name, missing in sorted(gaps.items()))
        + ". A key carried by one path and dropped by its sibling is invisible "
          "at both ends. Either emit it, or declare it under `missing_in` with the "
          "reason that path legitimately has nothing to put there.")


@pytest.mark.parametrize("group", sorted(SIBLINGS))
def test_every_declared_exception_is_still_a_real_one(group):
    """An exception that has stopped applying reads as a decision somebody made
    while exempting a key nobody looks at any more (L233, L336)."""
    spec = SIBLINGS[group]
    keys_by_payload = {name: emitted_keys(PAYLOADS[name])
                       for name in spec["payloads"]}

    for key, excuse in (spec.get("missing_in") or {}).items():
        without = excuse["payload"]
        assert without in keys_by_payload, (
            f"{group}: {key!r} is excused for {without}, which is not in this "
            f"group at all")
        assert key not in keys_by_payload[without], (
            f"{group}: {key!r} is excused because {without} legitimately has "
            f"nothing to put there, and {without} emits it now, so the "
            f"exception is exempting a key that no longer needs exempting")
        others = [n for n, keys in keys_by_payload.items()
                  if n != without and key in keys]
        assert others, (
            f"{group}: {key!r} is excused for {without} and no sibling emits "
            f"it either, so there is no difference here to excuse")


@pytest.mark.parametrize("group", sorted(SIBLINGS))
def test_every_exception_says_why(group):
    """A skip with no written reason beside neighbours that each carry one is
    evidence it was never reasoned about (L233)."""
    for key, excuse in (SIBLINGS[group].get("missing_in") or {}).items():
        assert (excuse.get("why") or "").strip(), (
            f"{group}: {key!r} is excused from the comparison with no reason "
            f"given, so nobody can tell a considered difference from an "
            f"oversight")


# ── several producers of ONE entry are parts, not rivals ─────────────────────


def multi_producer_payloads() -> list[str]:
    return sorted(name for name, spec in PAYLOADS.items()
                  if len(spec.get("python") or []) > 1)


def test_the_sweep_finds_the_entries_with_more_than_one_producer():
    """The positive control. A sweep matching nothing reports every entry as
    consistent, which is what the union already did (L98, L100)."""
    assert multi_producer_payloads(), (
        "no payload entry names more than one producer, so the check below "
        "passes over an empty set")


@pytest.mark.parametrize("name", multi_producer_payloads())
def test_the_producers_of_one_entry_write_disjoint_parts(name):
    """`emitted_keys` UNIONS an entry's producers, and that is only the right
    question while they are contributing different PARTS of one object.

    Measured 2026-09-04, all three such entries are exactly that, with zero
    keys in common: `generate_week` writes the days and `_write_results` adds
    `complete` and its neighbours; `_snapshot` and `_write`; `generate_media`
    and `_render_cover`. So the union is correct for them and there is nothing
    to fix.

    What the union would HIDE is two producers each building the whole shape,
    where a key only one of them writes still satisfies the entry. That is the
    #1023 defect, and an overlap is its signature: parts do not share keys,
    rivals do. So this is the guard on the assumption the union rests on,
    rather than a check on the three entries as they are today.

    If this ever goes red the answer is not to widen it. Either the two are
    genuinely rivals, in which case they belong in a sibling group above where
    they are compared key by key, or one of them is writing a key that is not
    its part.
    """
    per_producer = keys_per_producer(PAYLOADS[name])

    shared = set.intersection(*per_producer.values())

    assert not shared, (
        f"{name} is written by {sorted(per_producer)}, and they both write "
        f"{sorted(shared)}. Producers listed under one entry are meant to be "
        f"contributing different PARTS of one object, which is what makes "
        f"unioning them the right question. Two producers writing the same key "
        f"are rivals building the same shape, and the union then hides a key "
        f"only one of them writes (#1023).")


def test_two_rival_producers_would_be_caught():
    """The control, driven with a shape it invents, because all three real
    entries are disjoint and a check only ever run on clean input has never
    been seen to fail (L1)."""
    rivals = {"generate": {"caption", "alt_texts", "hashtags"},
              "revise": {"caption", "alt_texts"}}

    assert set.intersection(*rivals.values()) == {"caption", "alt_texts"}, (
        "two producers building the same shape share keys, which is the "
        "signature this check keys on")


# ── the check can actually fail ──────────────────────────────────────────────


def test_a_key_one_producer_dropped_is_caught():
    """The scenario #1023 asks for: a producer whose OWN contract entry is
    perfectly consistent while its sibling carries a key it does not.

    That is what makes this different from the existing per-payload check.
    Removing the key from a producer AND from its declared keys leaves that
    entry passing, and only the comparison against the sibling can see it.
    """
    gaps = divergence(
        {"generated": {"caption", "alt_texts", "alt_text_photo_paths"},
         "revised": {"caption", "alt_texts"}},
        missing_in={})

    assert gaps == {"revised": {"alt_text_photo_paths"}}, (
        f"a key the revision dropped was not reported: {gaps}")


def test_a_declared_exception_is_not_reported():
    gaps = divergence(
        {"generated": {"caption", "skipped_photos"}, "revised": {"caption"}},
        missing_in={"skipped_photos": {"payload": "revised", "why": "..."}})

    assert gaps == {}, f"a reasoned difference was reported as a fault: {gaps}"


def test_an_exception_does_not_excuse_a_second_missing_key():
    """The narrow form. An exception names ONE key, and a group with a real
    exception must still catch everything else (L324: a stand down condition no
    broader than the reason for standing down)."""
    gaps = divergence(
        {"generated": {"caption", "skipped_photos", "hashtags"},
         "revised": {"caption"}},
        missing_in={"skipped_photos": {"payload": "revised", "why": "..."}})

    assert gaps == {"revised": {"hashtags"}}, (
        f"the exception excused more than the key it names: {gaps}")


def test_an_exception_excuses_the_payload_it_names_and_no_other():
    """The half the old wording could not express. In a group of three, a key
    absent from one of them is excused for that one; the third still has to
    emit it (#1357)."""
    gaps = divergence(
        {"generated": {"body", "title"}, "revised": {"body", "title"},
         "swapped": {"body"}, "third": {"body"}},
        missing_in={"title": {"payload": "swapped", "why": "..."}})

    assert gaps == {"third": {"title"}}, (
        f"the exception was read as excusing every payload: {gaps}")
