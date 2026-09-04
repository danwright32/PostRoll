r"""#959: the prompts banning em dashes were written using em dashes throughout.

The caption prompt, the blog prompt and the brand voice document all instruct
Claude never to use an em dash. Measured 2026-08-29: 66 in the text sent to the
model from `postroll/ai/generate_captions.py`, 56 in `postroll/ai/generate_blog.py`,
63 in `postroll/assets/brand-voice.md`, and 20 in `postroll/ai/ai_tells.py`.

A model derives its contract from what it is SHOWN at least as much as from what
it is told, and anything a prompt bans must be absent from the whole payload it
receives rather than merely forbidden in one sentence of it (L270). The brand
voice document is the single strongest example of how the writing should read,
and it was the worst offender per line.

`strip_em_dashes` catches what comes back, which is why nothing has gone visibly
wrong. A deterministic cleaner working around a prompt that contradicts itself
is a backstop doing the prompt's job.

## The characters that must survive

Three kinds, and they are all in `ai_tells.py`:

- the two patterns the rule is expressed as, `_DASH_RANGE_RE` and `_DASH_RE`
- the membership test that short circuits `strip_em_dashes`
- the instruction that QUOTES the character for the model, which has to reach
  it as a real character or the ban names nothing

Every one is written as a `\u2014` escape, so the file itself holds no literal
dash and the pre-push style hook has nothing to catch, while the runtime string
is unchanged. That distinction is what this file checks in both directions: the
FILES carry none, and the RUNTIME ban still shows one.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from postroll.ai import ai_tells

REPO_ROOT = Path(__file__).resolve().parent.parent

# As escapes, for the reason this whole file is about: a check that a
# character is absent must not itself be a place the character is present,
# and the pre-push style hook cannot tell the line banning it from a line
# using it. The runtime strings are identical.
EM, EN = "\u2014", "\u2013"

#: Every file whose prose reaches the model, or teaches whoever writes the next
#: one. Named rather than globbed, because the point is these four and a glob
#: over the package would quietly cover files nobody chose.
PROMPT_FILES = [
    "postroll/ai/generate_captions.py",
    "postroll/ai/generate_blog.py",
    "postroll/assets/brand-voice.md",
    "postroll/ai/ai_tells.py",
]


@pytest.mark.parametrize("name", PROMPT_FILES)
def test_no_prompt_file_holds_a_literal_em_or_en_dash(name: str) -> None:
    text = (REPO_ROOT / name).read_text(encoding="utf-8")

    offending = [
        f"{n}: {line.strip()}"
        for n, line in enumerate(text.splitlines(), 1)
        if EM in line or EN in line
    ]

    assert not offending, (
        f"{name} demonstrates the character it bans on {len(offending)} lines. "
        f"A model derives its contract from what it is shown at least as much "
        f"as from what it is told (L270). Where the character has to reach the "
        f"model, write it as a \\u2014 escape so the runtime string is "
        f"unchanged and the file holds none:\n" + "\n".join(offending[:10]))


def test_the_ban_still_shows_the_model_the_character_it_names() -> None:
    """The other direction, and without it the check above is satisfied by a
    prompt that stopped naming the character at all (L283).

    A rule that says "no em dashes" without one is a rule about a word."""
    prompt = ai_tells.build_review_prompt(
        draft_json="{}", humanizer_rules="RULES", brand_voice="VOICE",
        output_shape_description="the same shape")

    assert EM in prompt, (
        "the hard ban no longer quotes the character it bans, so the model is "
        "told about 'em dashes' and never shown one")


def test_everything_the_prompt_contributes_itself_is_otherwise_clean() -> None:
    """What the model receives, not what one file says (L270).

    The draft and the rules come from outside and may say anything; the draft is
    the thing being cleaned. Everything the prompt builder supplies has to be
    clean apart from the one line quoting the character.
    """
    prompt = ai_tells.build_review_prompt(
        draft_json="{}", humanizer_rules="RULES", brand_voice="VOICE",
        output_shape_description="the same shape")

    showing = [line for line in prompt.splitlines() if EM in line or EN in line]

    assert len(showing) == 1, (
        "the prompt shows the banned character on more than the one line that "
        "names it, so every other one reads as permission:\n"
        + "\n".join(showing))
    assert "NO em dashes" in showing[0], (
        f"the one line showing the character is not the ban itself: {showing[0]}")


def test_the_brand_voice_sample_reaches_the_model_clean() -> None:
    """The strongest example in the payload (L562).

    A named rule is copied through its worked example, so an example that
    contradicts the rule teaches the inverse and is then defended with the
    rule's own authority.
    """
    voice = (REPO_ROOT / "postroll/assets/brand-voice.md").read_text(encoding="utf-8")

    assert EM not in voice and EN not in voice


# ── the backstop still works on the real characters ──────────────────────────

def test_the_backstop_still_strips_a_real_em_dash() -> None:
    # The patterns are escapes now rather than literals. An escape written into
    # a RAW string is not a character, and a pattern matching nothing reports
    # every draft as clean (L100), so this is asserted against real characters
    # rather than against the source.
    assert ai_tells.strip_em_dashes(f"a{EM}b") == "a, b"
    assert ai_tells.strip_em_dashes(f"a {EN} b") == "a, b"


def test_a_digit_range_still_becomes_a_hyphen() -> None:
    assert ai_tells.strip_em_dashes(f"7{EN}9pm") == "7-9pm"


def test_text_with_no_dash_is_returned_untouched() -> None:
    # The short circuit reads the same two characters the patterns do, so it
    # fails the same way if either is written wrong.
    assert ai_tells.strip_em_dashes("nothing to do here") == "nothing to do here"
