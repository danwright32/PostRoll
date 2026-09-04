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
               only_in: dict[str, dict]) -> dict[str, set[str]]:
    """Keys that one payload in a group emits and another does not.

    Pure, so the tests below can drive it with a shape they invent as well as
    with the real contract: the real one is expected to be clean, and a check
    that has only ever been run on clean input has never been seen to fail (L1).
    """
    everywhere = set().union(*keys_by_payload.values()) if keys_by_payload else set()
    excused = {key for key, spec in only_in.items()
               if spec.get("payload") in keys_by_payload}
    missing = {}
    for name, keys in keys_by_payload.items():
        gap = {k for k in everywhere - keys if k not in excused}
        if gap:
            missing[name] = gap
    return missing


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

    gaps = divergence(keys_by_payload, spec.get("only_in") or {})

    assert not gaps, (
        f"in the {group!r} group, these producers are missing keys their "
        f"sibling emits: "
        + "; ".join(f"{name} lacks {sorted(missing)}"
                    for name, missing in sorted(gaps.items()))
        + ". A key carried by one path and dropped by its sibling is invisible "
          "at both ends. Either emit it, or declare it under `only_in` with the "
          "reason that path legitimately has nothing to put there.")


@pytest.mark.parametrize("group", sorted(SIBLINGS))
def test_every_declared_exception_is_still_a_real_one(group):
    """An exception that has stopped applying reads as a decision somebody made
    while exempting a key nobody looks at any more (L233, L336)."""
    spec = SIBLINGS[group]
    keys_by_payload = {name: emitted_keys(PAYLOADS[name])
                       for name in spec["payloads"]}

    for key, excuse in (spec.get("only_in") or {}).items():
        owner = excuse["payload"]
        assert key in keys_by_payload.get(owner, set()), (
            f"{group}: {key!r} is excused because only {owner} emits it, and "
            f"{owner} does not emit it at all any more")
        others = [n for n, keys in keys_by_payload.items()
                  if n != owner and key in keys]
        assert not others, (
            f"{group}: {key!r} is excused as belonging only to {owner}, but "
            f"{others} emit it too, so the exception is exempting a key that "
            f"no longer needs exempting")


@pytest.mark.parametrize("group", sorted(SIBLINGS))
def test_every_exception_says_why(group):
    """A skip with no written reason beside neighbours that each carry one is
    evidence it was never reasoned about (L233)."""
    for key, excuse in (SIBLINGS[group].get("only_in") or {}).items():
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
        only_in={})

    assert gaps == {"revised": {"alt_text_photo_paths"}}, (
        f"a key the revision dropped was not reported: {gaps}")


def test_a_declared_exception_is_not_reported():
    gaps = divergence(
        {"generated": {"caption", "skipped_photos"}, "revised": {"caption"}},
        only_in={"skipped_photos": {"payload": "generated", "why": "..."}})

    assert gaps == {}, f"a reasoned difference was reported as a fault: {gaps}"


def test_an_exception_does_not_excuse_a_second_missing_key():
    """The narrow form. An exception names ONE key, and a group with a real
    exception must still catch everything else (L324: a stand down condition no
    broader than the reason for standing down)."""
    gaps = divergence(
        {"generated": {"caption", "skipped_photos", "hashtags"},
         "revised": {"caption"}},
        only_in={"skipped_photos": {"payload": "generated", "why": "..."}})

    assert gaps == {"revised": {"hashtags"}}, (
        f"the exception excused more than the key it names: {gaps}")
