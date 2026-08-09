"""#110: captions need the same deterministic backstop the blog has.

The caption prompt bans engagement bait ("link in bio", "swipe to see more",
"DM me") and the generic second person, and the blog enforces its equivalent
bans in code after the model has answered. Captions relied on the prompt alone.

A rule that lives only in a prompt is a hope. These are hard, checkable strings:
they either appear or they do not, so a regex settles it and no second ask of
the model is needed to decide. What the model IS still needed for is the
rewrite, which is why a hit triggers one focused call rather than a blunt
deletion that would leave a caption reading like a ransom note.

The closing question ban is deliberately not enforced here. "What do you think?"
is a shape rather than a string, and a regex that tried to catch it would either
miss the ones phrased differently or fire on a legitimate sentence ending in a
question mark. A check that cries wolf gets ignored.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai.caption_quality import (
    BANNED_PHRASE_RE,
    banned_phrases_in,
    has_generic_second_person,
)


# ── what the checks catch ─────────────────────────────────────────────────────

@pytest.mark.parametrize("caption", [
    "Full set from Saturday. Link in bio.",
    "More from the night, swipe to see more.",
    "DM me for prints.",
    "link in bio for the full gallery",
])
def test_engagement_bait_is_caught(caption):
    assert banned_phrases_in(caption), f"missed: {caption}"


def test_the_phrase_that_was_found_is_named():
    # "This caption is wrong" is not actionable. Which phrase it was decides
    # what the rewrite has to remove.
    found = banned_phrases_in("Full set from Saturday. Link in bio.")

    assert any("link in bio" in f.lower() for f in found)


@pytest.mark.parametrize("caption", [
    "You should have been there.",
    "Your favourite band played third.",
    "If you were at the back you missed it.",
])
def test_the_generic_second_person_is_caught(caption):
    assert has_generic_second_person(caption), f"missed: {caption}"


# ── what they must NOT catch ──────────────────────────────────────────────────

def test_a_quoted_you_is_left_alone():
    # Someone on stage saying "you" is a fact about the night, not the caption
    # addressing the reader.
    caption = 'Suero stopped mid-verse to say "you already know this one".'

    assert not has_generic_second_person(caption)


def test_an_ordinary_caption_trips_nothing():
    caption = ("BLUDLINE played the full set at Greenwich House, ten players "
               "rotating through the mic stands.")

    assert banned_phrases_in(caption) == []
    assert not has_generic_second_person(caption)


def test_a_handle_containing_you_is_not_second_person():
    # @youngpeopleschorus is a real account name, not an address to the reader.
    caption = "Closing set from @youngpeopleschorus at Carnegie Hall."

    assert not has_generic_second_person(caption)


def test_a_word_merely_containing_you_is_not_a_match():
    assert not has_generic_second_person("The younger players opened.")


def test_a_closing_question_is_not_flagged():
    # Deliberately out of scope: a shape, not a string, and a regex for it
    # would fire on legitimate sentences.
    caption = "Nobody expected the encore. What do you think they opened with?"

    assert banned_phrases_in(caption) == []


# ── the caption pipeline uses it ──────────────────────────────────────────────

def _generate(fake_caption, rewrite, photo):
    from postroll.ai import generate_captions

    calls = {"n": 0}

    def fake_run_json(prompt, **kw):
        calls["n"] += 1
        return {"caption": fake_caption, "hashtags": [],
                "alt_texts": ["a"], "scene_labels": [None]}

    with patch("postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.generate_captions.run_prompt", side_effect=lambda p, **k: rewrite):
        return generate_captions.generate_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="sunday",
            photo_paths=[photo], program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=True)


@pytest.fixture
def photo(tmp_path):
    from PIL import Image
    p = tmp_path / "a.jpg"
    Image.new("RGB", (120, 90), (40, 60, 80)).save(p)
    return p


def test_a_caption_with_bait_is_rewritten(photo):
    result = _generate("Full set from Saturday. Link in bio.",
                       rewrite="Full set from Saturday.", photo=photo)

    assert "link in bio" not in result["caption"].lower()


def test_the_rewrite_is_kept_only_if_it_is_actually_clean(photo):
    # A rewrite that still carries the phrase is refused, so the backstop can
    # never make the caption worse or claim a fix it did not make.
    result = _generate("Full set from Saturday. Link in bio.",
                       rewrite="Still here, link in bio.", photo=photo)

    assert result["caption"] == "Full set from Saturday. Link in bio.", (
        "a rewrite that still offends must be rejected, leaving the original")


def test_a_clean_caption_costs_no_extra_call(photo):
    # The backstop must not add a call to every ordinary caption.
    from postroll.ai import generate_captions

    seen = {"rewrites": 0}

    def fake_run_json(prompt, **kw):
        return {"caption": "BLUDLINE played the full set at Greenwich House.",
                "hashtags": [], "alt_texts": ["a"], "scene_labels": [None]}

    def fake_run_prompt(prompt, **kw):
        seen["rewrites"] += 1
        return "unused"

    with patch("postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.generate_captions.run_prompt", side_effect=fake_run_prompt):
        generate_captions.generate_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="sunday",
            photo_paths=[photo], program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=True)

    assert seen["rewrites"] == 0


def test_a_failed_rewrite_call_keeps_the_original_caption(photo):
    # The rewrite is one more paid call and can fail for reasons that have
    # nothing to do with the caption: a rate limit, an overload, a network
    # blip. None of those justify losing a caption that was already paid for,
    # so the original survives and the problem is reported on stderr.
    from postroll.ai import generate_captions

    def fake_run_json(prompt, **kw):
        return {"caption": "Full set from Saturday. Link in bio.",
                "hashtags": [], "alt_texts": ["a"], "scene_labels": [None]}

    def boom(prompt, **kw):
        raise generate_captions.ClaudeError("rate_limit")

    with patch("postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.generate_captions.run_prompt", side_effect=boom):
        result = generate_captions.generate_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="sunday",
            photo_paths=[photo], program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=True)

    assert result["caption"] == "Full set from Saturday. Link in bio."


def test_a_failed_rewrite_says_so_rather_than_failing_silently(photo, capsys):
    # A backstop that quietly gives up looks exactly like one that found
    # nothing, and the caption ships with the bait still in it.
    from postroll.ai import generate_captions

    def fake_run_json(prompt, **kw):
        return {"caption": "Full set from Saturday. Link in bio.",
                "hashtags": [], "alt_texts": ["a"], "scene_labels": [None]}

    def boom(prompt, **kw):
        raise generate_captions.ClaudeError("rate_limit")

    with patch("postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.generate_captions.run_prompt", side_effect=boom):
        generate_captions.generate_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="sunday",
            photo_paths=[photo], program={"performers": [], "pieces": []},
            skip_humanizer=True, skip_voice_pass=True)

    assert "rewrite failed" in capsys.readouterr().err


def test_an_empty_rewrite_is_refused(photo):
    # A blank response must never be accepted as a clean caption: that would
    # replace a flawed caption with no caption at all.
    result = _generate("Full set from Saturday. Link in bio.",
                       rewrite="   ", photo=photo)

    assert result["caption"] == "Full set from Saturday. Link in bio."
