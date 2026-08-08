"""Tests for the humanizer loader and its integration with generators."""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import generate_blog, generate_captions
from postroll.ai.ai_tells import (
    HUMANIZER_DEFAULT_PATH,
    build_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
)


# === load_humanizer_rules ===


def test_load_humanizer_rules_from_explicit_path(tmp_path):
    fake = tmp_path / "SKILL.md"
    fake.write_text("# Humanizer rules\n- delve\n- tapestry\n")
    text = load_humanizer_rules(fake)
    assert "Humanizer rules" in text
    assert "delve" in text


def test_load_humanizer_rules_raises_on_missing(tmp_path):
    missing = tmp_path / "nope" / "SKILL.md"
    with pytest.raises(FileNotFoundError, match="Humanizer skill not found"):
        load_humanizer_rules(missing)


def test_default_path_is_under_claude_skills():
    assert HUMANIZER_DEFAULT_PATH.parts[-3:] == ("skills", "humanizer", "SKILL.md")
    assert HUMANIZER_DEFAULT_PATH.parts[-4] == ".claude"


# === is_humanizer_available ===


def test_is_humanizer_available_true_when_file_exists(tmp_path):
    fake = tmp_path / "SKILL.md"
    fake.write_text("anything")
    assert is_humanizer_available(fake) is True


def test_is_humanizer_available_false_when_missing(tmp_path):
    assert is_humanizer_available(tmp_path / "missing.md") is False


# === build_review_prompt ===


def test_review_prompt_includes_humanizer_rules_and_brand_voice():
    prompt = build_review_prompt(
        draft_json='{"caption": "x"}',
        humanizer_rules="- avoid delve\n- avoid tapestry",
        brand_voice="Dan's voice is direct and observational.",
        output_shape_description="{caption: string}",
    )
    assert "avoid delve" in prompt
    assert "Dan's voice is direct" in prompt
    assert '{"caption": "x"}' in prompt
    assert "{caption: string}" in prompt
    # Includes humanizer's draft → audit → revise loop
    assert "draft" in prompt.lower() and "revise" in prompt.lower()
    # Says return only the cleaned JSON
    assert "ONLY" in prompt or "only" in prompt


# === Caption integration ===


def test_caption_runs_humanizer_review_when_available(sample_photo, tmp_path):
    """When humanizer is installed, the caption generator runs THREE Claude calls:
    draft -> voice pass -> humanizer (LAST, always). Humanizer is the final word."""
    fake_humanizer = tmp_path / "SKILL.md"
    fake_humanizer.write_text("# humanizer rules\n- avoid delve")

    calls: list[str] = []

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        calls.append(prompt)
        if len(calls) == 1:
            # Pass 1: draft with AI tells
            return {
                "alt_texts": ["alt"],
                "scene_labels": [None],
                "caption": "A pivotal moment, delving into the music.",
                "hashtags": ["#x"],
            }
        if len(calls) == 2:
            # Pass 2: voice pass output — voice-matched but may still have tells
            return {
                "alt_texts": ["voiced alt"],
                "scene_labels": [None],
                "caption": "A pivotal moment in Dan's voice.",
                "hashtags": ["#x"],
            }
        # Pass 3 (FINAL): humanizer — cleaned of all AI tells
        return {
            "alt_texts": ["cleaned alt"],
            "scene_labels": [None],
            "caption": "A specific moment.",
            "hashtags": ["#x"],
        }

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json
    ):
        result = generate_captions.generate_caption(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            day="sunday",
            photo_paths=[sample_photo],
            program={"performers": [], "pieces": []},
            humanizer_path=fake_humanizer,
        )

    assert len(calls) == 3
    # Pass 1 is the draft — brand voice in prompt, no humanizer rules
    assert "Dan Wright" in calls[0]
    assert "avoid delve" not in calls[0]
    # Pass 2 is the voice pass — brand voice, no humanizer rules
    assert "voice editor" in calls[1].lower() or "voice match" in calls[1].lower()
    assert "avoid delve" not in calls[1]
    # Pass 3 is humanizer — has humanizer rules AND sees the voice-pass output
    assert "humanizer rules" in calls[2].lower() or "avoid delve" in calls[2]
    assert "voiced alt" in calls[2]  # humanizer received pass 2's output
    # Hard-ban scan included
    assert "em dash" in calls[2].lower() or "no em dashes" in calls[2].lower()
    # Final result is from pass 3 (humanizer is the last word)
    assert result["caption"] == "A specific moment."


def test_caption_skips_humanizer_when_skip_flag_set(sample_photo, tmp_path):
    """skip_humanizer=True bypasses the review pass even if installed."""
    fake_humanizer = tmp_path / "SKILL.md"
    fake_humanizer.write_text("# rules")

    calls: list[str] = []

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        calls.append(prompt)
        return {"alt_texts": ["alt"], "scene_labels": [None], "caption": "x", "hashtags": []}

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json
    ):
        generate_captions.generate_caption(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            day="sunday",
            photo_paths=[sample_photo],
            program={"performers": [], "pieces": []},
            humanizer_path=fake_humanizer,
            skip_humanizer=True,
            skip_voice_pass=True,
        )

    assert len(calls) == 1


def test_caption_skips_humanizer_when_not_installed(sample_photo, tmp_path):
    """If humanizer isn't installed, the humanizer pass silently skips.
    Voice pass is independent of humanizer install, so skip it explicitly."""
    missing = tmp_path / "missing.md"

    calls: list[str] = []

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        calls.append(prompt)
        return {"alt_texts": ["alt"], "scene_labels": [None], "caption": "x", "hashtags": []}

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json
    ):
        generate_captions.generate_caption(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            day="sunday",
            photo_paths=[sample_photo],
            program={"performers": [], "pieces": []},
            humanizer_path=missing,
            skip_voice_pass=True,
        )

    assert len(calls) == 1


# === Blog integration ===


def test_blog_runs_humanizer_review_when_available(sample_photo, tmp_path):
    fake_humanizer = tmp_path / "SKILL.md"
    fake_humanizer.write_text("# humanizer rules\n- avoid delve")

    calls: list[str] = []

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        calls.append(prompt)
        if len(calls) == 1:
            return {"title": "Pivotal moment", "body": "It delves into a tapestry.", "photo_count": 4}
        return {"title": "A specific title", "body": "It's a specific clean body.", "photo_count": 4}

    with patch(
        "postroll.ai.generate_blog.run_json_prompt", side_effect=fake_run_json
    ):
        result = generate_blog.generate_blog(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            program={"performers": [], "pieces": []},
            photo_paths=[sample_photo] * 4,
            humanizer_path=fake_humanizer,
        )

    # Pipeline: draft (call 0) → voice pass (call 1) → humanizer (call 2)
    assert len(calls) == 3
    assert "Pivotal moment" in calls[1]  # voice pass receives the draft output
    # Title is deterministic: "{event} at {venue}".
    assert result["title"] == "E at V"
    assert result["body"] == "It's a specific clean body."


def test_blog_skips_humanizer_when_skip_flag_set(sample_photo, tmp_path):
    fake_humanizer = tmp_path / "SKILL.md"
    fake_humanizer.write_text("# rules")

    calls: list[str] = []

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        calls.append(prompt)
        return {"title": "x", "body": "I'm here.", "photo_count": 4}

    with patch(
        "postroll.ai.generate_blog.run_json_prompt", side_effect=fake_run_json
    ):
        generate_blog.generate_blog(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            program={"performers": [], "pieces": []},
            photo_paths=[sample_photo] * 4,
            humanizer_path=fake_humanizer,
            skip_humanizer=True,
            skip_voice_pass=True,
        )

    assert len(calls) == 1


# === deterministic backstops ===


class TestStripEmDashes:
    def test_em_dash_becomes_comma_join(self):
        from postroll.ai.ai_tells import strip_em_dashes
        assert strip_em_dashes("The hall was full — every seat taken.") == \
            "The hall was full, every seat taken."

    def test_en_dash_becomes_comma_join(self):
        from postroll.ai.ai_tells import strip_em_dashes
        assert strip_em_dashes("quiet – then loud") == "quiet, then loud"

    def test_numeric_range_becomes_hyphen(self):
        from postroll.ai.ai_tells import strip_em_dashes
        assert strip_em_dashes("Doors 7–9pm.") == "Doors 7-9pm."

    def test_clean_text_unchanged(self):
        from postroll.ai.ai_tells import strip_em_dashes
        text = "Already clean, with commas and a hyphenated well-known word."
        assert strip_em_dashes(text) is text


class TestMarkerPreservation:
    def test_extracts_sorted_filenames(self):
        from postroll.ai.ai_tells import photo_marker_filenames
        body = "p1\n\n[PHOTO: b.jpg | alt two]\n\np2\n\n[PHOTO: a.jpg | alt one]"
        assert photo_marker_filenames(body) == ["a.jpg", "b.jpg"]

    def test_validator_passes_when_markers_intact(self):
        from postroll.ai.ai_tells import markers_preserved_validator
        prior = {"body": "[PHOTO: a.jpg | x]\n\ntext"}
        revised = {"body": "better text\n\n[PHOTO: a.jpg | x]"}
        assert markers_preserved_validator(prior, revised) is None

    def test_validator_flags_dropped_marker(self):
        from postroll.ai.ai_tells import markers_preserved_validator
        prior = {"body": "[PHOTO: a.jpg | x]\n\n[PHOTO: b.jpg | y]"}
        revised = {"body": "[PHOTO: a.jpg | x]\n\nprose only now"}
        assert markers_preserved_validator(prior, revised) is not None

    def test_validator_flags_renamed_marker(self):
        from postroll.ai.ai_tells import markers_preserved_validator
        prior = {"body": "[PHOTO: a.jpg | x]"}
        revised = {"body": "[PHOTO: hallucinated.jpg | x]"}
        assert markers_preserved_validator(prior, revised) is not None
