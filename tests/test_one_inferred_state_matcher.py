"""The blog and caption alt checks apply one inferred-state rule (#1224).

`INFERRED_STATE` and `DIRECTED_INTENT` were shared and the matching built on
them was not: two identical lines, once in `blog_quality.check_alt_text` and
once in `caption_quality.check_caption_alt_texts`.

Sharing the word lists while copying the matcher is the half measure that makes
divergence likely rather than unlikely. The lists LOOK like the single source
of truth, so a change to how they are APPLIED, a word boundary, case folding, a
new pattern family, gets made in whichever file the author had open, and a
shared NAME is read as evidence of shared BEHAVIOUR so nobody compares the two
again (L263, L370).

Nothing was wrong when this was written: the copies were byte for byte. That is
the point at which to remove one, rather than after the first report of the two
disagreeing.

## What is deliberately NOT shared

Only the matching. The two paths word their findings differently and target
them differently, a marker filename against a photo name or position, so each
builds its own `Finding` from the hits.
"""

from __future__ import annotations

import inspect

import pytest

from postroll.ai import blog_quality, caption_quality
from postroll.ai.blog_quality import (
    DIRECTED_INTENT, INFERRED_STATE, check_alt_text, inferred_state_hits)
from postroll.ai.caption_quality import check_caption_alt_texts

#: Alt texts that each break the rule a different way, so agreement between the
#: two paths is tested across the shape of the rule rather than on one word.
#:
#: Every one is drawn from the lists themselves rather than invented, so a list
#: that is emptied or renamed makes these stop firing and the control below
#: fails rather than this file quietly proving nothing (L48, L98).
def _breaking_examples() -> list[str]:
    word = INFERRED_STATE[0]
    return [
        f"the performer looks {word} under the lights",
        f"a dancer, {word}, mid turn",
        f"{word} at the front of the stage",
    ]


BENIGN = "a dancer mid turn at the front of the stage, arms extended"


def test_the_two_checks_agree_about_every_breaking_example():
    """The guard this file exists to be.

    Same text, same rule, so the same hits. If the two matchers ever diverge,
    this is what says so, and it compares the CHECKS rather than the helper,
    because a shared helper that only one of them calls is the same defect
    wearing a better name (L3).
    """
    for alt in _breaking_examples():
        from_blog = [f for f in check_alt_text("a-photo.jpg", alt)
                     if f.code == "alt_text_inferred_state"]
        from_caption = [f for f in check_caption_alt_texts([alt], band=None)
                        if f.code == "alt_text_inferred_state"]

        assert bool(from_blog) == bool(from_caption), (
            f"the blog check and the caption check disagree about {alt!r}: "
            f"blog {'found' if from_blog else 'found nothing'}, caption "
            f"{'found' if from_caption else 'found nothing'}")
        assert from_blog, (
            f"neither check flagged {alt!r}, so this example proves nothing "
            f"about them agreeing (L159)")


def test_they_agree_that_a_plain_description_is_fine():
    """The other half. Two checks that both flagged everything would also agree
    on every example above (L104)."""
    from_blog = [f for f in check_alt_text("a-photo.jpg", BENIGN)
                 if f.code == "alt_text_inferred_state"]
    from_caption = [f for f in check_caption_alt_texts([BENIGN], band=None)
                    if f.code == "alt_text_inferred_state"]

    assert not from_blog and not from_caption, (
        f"a plain description of what the camera recorded was flagged: "
        f"{from_blog or from_caption}")


def test_the_matcher_is_written_once():
    """Structural, and the reason the agreement above stays true rather than
    being true today.

    Two copies of one rule either side of a boundary are never compared and can
    implement different things indefinitely, while every call site on each side
    reads as correct in isolation (L263).
    """
    copies = [name for name, module in
              (("blog_quality", blog_quality), ("caption_quality", caption_quality))
              if "for w in INFERRED_STATE" in inspect.getsource(module)
              and "def inferred_state_hits" not in _defining_line(module)]

    assert len(copies) <= 1, (
        f"{copies} each match INFERRED_STATE themselves rather than calling the "
        f"shared matcher, so the word lists are shared and their application is "
        f"not, which is the state this was written to remove")


def _defining_line(module) -> str:
    source = inspect.getsource(module)
    at = source.find("for w in INFERRED_STATE")
    return source[max(0, at - 400):at]


def test_the_hits_name_what_was_matched():
    """The findings quote the words they matched, so a person can see what the
    check objected to rather than being told a rule was broken (L80)."""
    word = INFERRED_STATE[0]

    hits = inferred_state_hits(f"the performer looks {word} under the lights")

    assert word in hits, f"the matched word is not among the hits: {hits}"


def test_both_families_are_matched():
    """The word list and the phrase patterns are two halves of one rule, and a
    matcher that dropped either would still pass every agreement test above,
    because both checks would drop it together (L70).

    The phrase is built by asking the pattern itself what it matches rather
    than by writing one out here, so a rewritten pattern is exercised rather
    than a remembered example of it (L48).
    """
    assert INFERRED_STATE and DIRECTED_INTENT, "a list is empty, so this proves nothing"

    from_the_word_list = inferred_state_hits(
        f"a dancer {INFERRED_STATE[0]} on stage")
    assert from_the_word_list, "the INFERRED_STATE word list is not matched at all"

    phrase = _a_phrase_matching(DIRECTED_INTENT[0])
    from_the_patterns = inferred_state_hits(f"a dancer {phrase} the wings")
    assert from_the_patterns, (
        f"the DIRECTED_INTENT patterns are not matched at all: {phrase!r} "
        f"produced no hits")


def _a_phrase_matching(pattern: str) -> str:
    """The simplest literal the pattern accepts, taken from the pattern.

    `grinning (?:toward|towards|at)` becomes `grinning toward`. Only the
    alternation form these patterns use is handled, and anything else raises
    rather than returning a string that matches nothing and would make the
    check above pass by finding nothing (L98).
    """
    import re

    literal = re.sub(r"\(\?:([^)|]+)(?:\|[^)]*)?\)", r"\1", pattern)
    if "(" in literal or "\\" in literal:
        raise AssertionError(
            f"{pattern!r} is not a plain alternation any more, so this cannot "
            f"build a sample from it without reimplementing the rule. Teach "
            f"this helper the new form rather than skipping (L98).")
    return literal
