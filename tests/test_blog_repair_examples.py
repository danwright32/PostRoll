"""#1161: the repair prompt carries worked examples, and every one of them
clears the rules that same prompt states.

Phase 5c specified few shot examples and they were not built: the prompt sent
rules only. The reasoning for filtering them was specific and still holds. A
prompt that BANS a thing and then demonstrates it teaches the demonstration,
and the demonstration outweighs the instruction (L270). This repo paid for that
at scale in #959.

So the examples are not simply "markers Dan corrected". `expectations.json`
records in his own words that the corrected `one_man_odyssey` marker at -92
still fires `alt_text_inferred_state`, which is one of the very codes this
repairer exists to fix. Every example is filtered through `check_alt_text`, and
the filter is asserted NOT VACUOUS: if it removed nothing, it would be a
comment rather than a filter, and this file would pass while the prompt taught
the rule it bans.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai.blog_quality import _markers, check_alt_text
from postroll.ai.blog_repair import PROMPT, render_examples
from postroll.ai.blog_repair_examples import EXAMPLES

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "blog_corrections"


def _corrections() -> list[tuple[str, str, str, list[str]]]:
    """Every (before, after, venue, performers) Dan actually made."""
    out = []
    for name in ("bludline", "one_man_odyssey"):
        data = json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))
        performers = [p.get("name", "") for p
                      in (data.get("program") or {}).get("performers") or []]
        draft = dict(_markers(data["draft"]))
        for marker, alt in _markers(data["corrected"]):
            was = draft.get(marker)
            if was and was != alt:
                out.append((was, alt, data["venue"], performers))
    return out


def test_there_are_examples_at_all():
    """Without this, every test below passes over an empty tuple (L159)."""
    assert len(EXAMPLES) >= 3, EXAMPLES


@pytest.mark.parametrize("example", EXAMPLES, ids=lambda e: e.after[:40])
def test_every_example_clears_every_rule_the_prompt_states(example):
    """The rule this issue exists for. An example that breaks a rule the same
    prompt bans teaches the model to break it."""
    codes = [f.code for f in check_alt_text(
        "example.jpg", example.after, venue=example.venue,
        performers=list(example.performers))]
    assert codes == [], (
        f"an example placed in the repair prompt breaks {codes}: "
        f"{example.after!r}")


@pytest.mark.parametrize("example", EXAMPLES, ids=lambda e: e.after[:40])
def test_every_example_is_a_correction_dan_actually_made(example):
    """Not written to look like one. An invented example is a fact about the
    voice nobody checked, and it would be defended as vetted (L48)."""
    pairs = {(before, after) for before, after, _v, _p in _corrections()}
    assert (example.before, example.after) in pairs, (
        f"this example is not one of the recorded corrections: {example.after!r}")


@pytest.mark.parametrize("example", EXAMPLES, ids=lambda e: e.after[:40])
def test_every_example_before_actually_broke_a_rule(example):
    """An example whose BEFORE was already clean demonstrates no repair, and
    it would sit in the prompt reading as guidance while teaching nothing."""
    codes = [f.code for f in check_alt_text(
        "example.jpg", example.before, venue=example.venue,
        performers=list(example.performers))]
    assert codes, f"this example's before text breaks nothing: {example.before!r}"


def test_the_filter_is_not_vacuous():
    """The measured case, and the whole reason the filter exists.

    `expectations.json` records that the corrected -92 marker still fires
    `alt_text_inferred_state`. If every correction passed clean, filtering
    through `check_alt_text` would remove nothing, and a test asserting the
    examples are clean would be asserting a property of the fixtures rather
    than of the filter (L182).
    """
    rejected = [after for _b, after, venue, performers in _corrections()
                if check_alt_text("x.jpg", after, venue=venue,
                                  performers=list(performers))]
    assert rejected, (
        "every recorded correction passes check_alt_text, so the filter "
        "removes nothing and proves nothing; re-check whether the rules or "
        "the fixtures changed before deleting this")
    shipped = {e.after for e in EXAMPLES}
    assert not (shipped & set(rejected)), (
        f"an example the filter should have removed is in the prompt: "
        f"{sorted(shipped & set(rejected))}")


# --- wired into the prompt, not merely defined (L3) ------------------------

def test_the_prompt_has_a_slot_for_the_examples():
    assert "{examples}" in PROMPT


def test_the_rendered_examples_carry_both_halves_of_each_pair():
    """A worked example is the CHANGE. Showing only the good version teaches
    what good looks like and nothing about what to do with a bad one."""
    rendered = render_examples()
    for example in EXAMPLES:
        assert example.before in rendered, example.before[:50]
        assert example.after in rendered, example.after[:50]


def test_the_rendered_examples_say_the_names_are_not_to_be_reused():
    """Every example names a real venue and real performers from another post.

    The acceptance check catches a bleed, because `alt_text_missing_venue` is
    run against THIS post's venue, so a rewrite naming the example's venue is
    refused and retried. That is a backstop, not a reason to leave the prompt
    silent about it.
    """
    rendered = render_examples().lower()
    assert "not" in rendered and ("name" in rendered or "venue" in rendered)
    assert "shape" in rendered or "this photograph" in rendered
