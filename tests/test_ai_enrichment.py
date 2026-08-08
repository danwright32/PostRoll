"""Tests for OCR enrichment via web research + shoot_type handling."""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import enrich_program as enrich_mod
from postroll.ai import generate_blog, generate_captions
from postroll.ai.claude_client import ClaudeError
from postroll.ai.enrich_program import (
    _build_hint_sections,
    _hint_looks_like_url,
    enrich_program,
    is_thin,
)


# === is_thin ===


def test_is_thin_empty_data():
    assert is_thin({}) is True


def test_is_thin_rich_classical_program():
    data = {
        "performers": [{"name": "X"}, {"name": "Y"}],
        "pieces": [
            {"composer": "Mahler", "title": "Symphony No. 2"},
            {"composer": "Brahms", "title": "Requiem"},
        ],
        "program_notes": "a" * 600,
    }
    assert is_thin(data) is False


def test_is_thin_sparse_play_program():
    """A play program with just a tagline and blurb should be thin."""
    data = {
        "performers": [],
        "pieces": [],
        "program_notes": "Three bad-ass women collide in a spa.",
        "organization_notes": "",
        "production_details": "",
    }
    assert is_thin(data) is True


def test_is_thin_one_performer_is_still_thin():
    """Boundary: a single performer with nothing else is thin."""
    data = {
        "performers": [{"name": "Unknown"}],
        "pieces": [],
        "program_notes": "",
    }
    assert is_thin(data) is True


def test_is_thin_many_performers_is_not_thin():
    data = {
        "performers": [{"name": f"p{i}"} for i in range(10)],
        "pieces": [],
        "program_notes": "",
    }
    assert is_thin(data) is False


def test_is_thin_long_notes_is_not_thin():
    data = {
        "performers": [],
        "pieces": [],
        "program_notes": "a" * 1000,
    }
    assert is_thin(data) is False


# === URL hint detection ===


def test_hint_looks_like_url_https():
    assert _hint_looks_like_url("https://www.chaintheatre.org/the-pushover") is True


def test_hint_looks_like_url_http():
    assert _hint_looks_like_url("http://example.com") is True


def test_hint_looks_like_url_text_hint():
    assert _hint_looks_like_url("The Pushover at Chain Theatre") is False


def test_hint_looks_like_url_with_whitespace():
    assert _hint_looks_like_url("  https://example.com  ") is True


# === Hint section building ===


def test_build_hint_sections_with_url():
    section, process = _build_hint_sections("https://www.chaintheatre.org/the-pushover")
    assert "chaintheatre" in section
    assert "WebFetch" in process
    assert "STARTING point" in section or "starting point" in process


def test_build_hint_sections_with_text():
    section, process = _build_hint_sections("The Pushover")
    assert "The Pushover" in section
    assert "search seed" in process.lower() or "search" in process.lower()


def test_build_hint_sections_without_hint():
    section, process = _build_hint_sections(None)
    assert "No hint" in section
    assert process == ""


# === enrich_program (mocked) ===


def test_enrich_program_requires_image():
    with pytest.raises(ValueError, match="At least one image"):
        enrich_program({}, [])


def test_enrich_program_raises_on_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        enrich_program({}, [tmp_path / "nope.jpg"])


def test_enrich_program_preserves_existing_ocr_fields(sample_photo):
    """Enrichment must not wipe out fields that already have content."""
    existing_ocr = {
        "performers": [{"name": "Real Name From OCR", "role": "actor"}],
        "pieces": [],
        "organization_notes": "",
        "program_notes": "",
        "venue_notes": "",
        "production_details": "",
        "other": "",
    }
    # Claude returns new data that happens to omit performers
    fake_response = {
        "pieces": [{"composer": "Kate Gill", "title": "The Pushover"}],
        "production_details": "Directed by X at Chain Theatre",
        "_enrichment": {
            "researched_event_identity": "The Pushover at Chain Theatre",
            "confidence": "high",
            "sources_used": ["https://www.chaintheatre.org/the-pushover"],
            "enriched_fields": ["pieces", "production_details"],
            "notes_for_human": "",
        },
    }
    with patch(
        "postroll.ai.enrich_program.run_json_prompt", return_value=fake_response
    ):
        result = enrich_program(existing_ocr, [sample_photo])

    # OCR performers should survive since Claude's response omitted that key
    assert result["performers"] == [{"name": "Real Name From OCR", "role": "actor"}]
    # New enriched fields should be present
    assert result["pieces"][0]["title"] == "The Pushover"
    assert "Chain Theatre" in result["production_details"]
    # Metadata block preserved
    assert result["_enrichment"]["confidence"] == "high"


def test_enrich_program_empty_values_do_not_erase_ocr_fields(sample_photo):
    """Claude is told to output the full schema, so explicit empty lists and
    strings are common. They must never replace real OCR content."""
    existing_ocr = {
        "performers": [{"name": "Real Name From OCR", "role": "actor"}],
        "pieces": [{"composer": "Kate Gill", "title": "The Pushover"}],
        "scenes": [],
        "organization_notes": "Founded in 1990.",
        "program_notes": "",
        "venue_notes": "",
        "production_details": "",
        "other": "",
    }
    # Full schema response with empty values for fields OCR already filled
    fake_response = {
        "performers": [],
        "pieces": [],
        "scenes": [],
        "organization_notes": "",
        "program_notes": "Premiered off Broadway.",
        "venue_notes": "",
        "production_details": "",
        "other": "",
        "_enrichment": {"enriched_fields": ["program_notes"]},
    }
    with patch(
        "postroll.ai.enrich_program.run_json_prompt", return_value=fake_response
    ):
        result = enrich_program(existing_ocr, [sample_photo])

    # Explicit empties must not clobber existing content
    assert result["performers"] == [{"name": "Real Name From OCR", "role": "actor"}]
    assert result["pieces"][0]["title"] == "The Pushover"
    assert result["organization_notes"] == "Founded in 1990."
    # Genuinely new content still lands
    assert result["program_notes"] == "Premiered off Broadway."
    # Fields empty on both sides stay empty
    assert result["venue_notes"] == ""


def test_enrich_program_passes_url_hint_to_prompt(sample_photo):
    captured = {}

    def fake_run(prompt, timeout=900, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        captured["allowed_tools"] = allowed_tools
        return {"_enrichment": {}}

    with patch(
        "postroll.ai.enrich_program.run_json_prompt", side_effect=fake_run
    ):
        enrich_program(
            {},
            [sample_photo],
            hint="https://www.chaintheatre.org/the-pushover",
        )

    # The URL must reach the prompt
    assert "chaintheatre.org/the-pushover" in captured["prompt"]
    # WebFetch instruction for URLs
    assert "WebFetch" in captured["prompt"]
    # Must still tell Claude to search beyond the URL
    assert "starting point" in captured["prompt"].lower()
    assert "not" in captured["prompt"].lower()  # "not the final answer" etc.
    # Allowed tools should include web tools
    assert "WebSearch" in captured["allowed_tools"]
    assert "WebFetch" in captured["allowed_tools"]
    assert "Read" in captured["allowed_tools"]


def test_enrich_program_text_hint_is_search_seed(sample_photo):
    captured = {}

    def fake_run(prompt, timeout=900, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        return {"_enrichment": {}}

    with patch(
        "postroll.ai.enrich_program.run_json_prompt", side_effect=fake_run
    ):
        enrich_program({}, [sample_photo], hint="The Pushover at Chain Theatre")

    assert "The Pushover at Chain Theatre" in captured["prompt"]


def test_enrich_program_no_hint_still_works(sample_photo):
    captured = {}

    def fake_run(prompt, timeout=900, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        return {"_enrichment": {}}

    with patch(
        "postroll.ai.enrich_program.run_json_prompt", side_effect=fake_run
    ):
        enrich_program({}, [sample_photo])

    assert "No hint" in captured["prompt"]


def test_enrich_program_raises_on_non_dict_response(sample_photo):
    with patch(
        "postroll.ai.enrich_program.run_json_prompt",
        return_value=["not", "a", "dict"],
    ):
        with pytest.raises(ClaudeError, match="Expected JSON object"):
            enrich_program({}, [sample_photo])


# === shoot_type propagation ===


def test_caption_passes_shoot_type_to_prompt(sample_photo):
    captured = {}

    def fake_run(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        return {"caption": "x", "hashtags": [], "alt_text": "x"}

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run
    ):
        generate_captions.generate_caption(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            day="sunday",
            photo_paths=[sample_photo],
            program={"performers": [], "pieces": []},
            shoot_type="photo_call",
        )

    assert "photo_call" in captured["prompt"]
    # Must warn Claude not to fabricate audience reactions
    assert "audience" in captured["prompt"].lower()


def test_caption_defaults_to_performance(sample_photo):
    captured = {}

    def fake_run(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        return {"caption": "x", "hashtags": [], "alt_text": "x"}

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run
    ):
        generate_captions.generate_caption(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            day="sunday",
            photo_paths=[sample_photo],
            program={"performers": [], "pieces": []},
        )

    assert "performance" in captured["prompt"]


def test_blog_passes_shoot_type_to_prompt(sample_photo):
    captured = {}

    def fake_run(prompt, timeout=600, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        return {"title": "x", "body": "I'm here.", "photo_count": 4}

    with patch(
        "postroll.ai.generate_blog.run_json_prompt", side_effect=fake_run
    ):
        generate_blog.generate_blog(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            program={"performers": [], "pieces": []},
            photo_paths=[sample_photo] * 4,
            shoot_type="photo_call",
        )

    assert "photo_call" in captured["prompt"]
    # Brand voice section about shoot types must reach the prompt
    assert "Honor what Dan actually witnessed" in captured["prompt"]


def test_blog_passes_production_details_to_prompt(sample_photo):
    captured = {}

    def fake_run(prompt, timeout=600, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        return {"title": "x", "body": "I'm here.", "photo_count": 4}

    with patch(
        "postroll.ai.generate_blog.run_json_prompt", side_effect=fake_run
    ):
        generate_blog.generate_blog(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            program={
                "performers": [],
                "pieces": [],
                "production_details": "Directed by Jane Doe. Opening Feb 15, 2026.",
            },
            photo_paths=[sample_photo] * 4,
            skip_humanizer=True,
            skip_voice_pass=True,
        )

    assert "Directed by Jane Doe" in captured["prompt"]
