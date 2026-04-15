"""Tests for the AI generator modules.

These mock the Claude subprocess so the tests are fast, deterministic,
and don't require a real `claude` binary. They verify input validation,
prompt construction, and result shaping.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

from postroll.ai import generate_blog, generate_captions, ocr_program
from postroll.ai.claude_client import ClaudeError
from postroll.ai.generate_captions import _format_performers, _format_pieces, format_for_post


# === Helpers / formatters ===


def test_format_performers_empty():
    assert _format_performers([]) == "(none listed)"


def test_format_performers_with_role_and_instrument():
    out = _format_performers(
        [
            {"name": "Lauren Snouffer", "role": "soloist", "voice_or_instrument": "soprano"},
            {"name": "Jonathan Griffith", "role": "conductor", "voice_or_instrument": None},
        ]
    )
    assert "Lauren Snouffer" in out
    assert "soprano" in out
    assert "Jonathan Griffith" in out
    assert "conductor" in out


def test_format_pieces_empty():
    assert _format_pieces([]) == "(none listed)"


def test_format_pieces_basic():
    out = _format_pieces(
        [{"composer": "Mahler", "title": "Symphony No. 2"}]
    )
    assert "Mahler" in out
    assert "Symphony No. 2" in out


def test_format_for_post_combines_caption_and_hashtags():
    rendered = format_for_post(
        {"caption": "A specific moment.", "hashtags": ["#dwphotony", "#carnegiehall"]}
    )
    assert "A specific moment." in rendered
    assert "#dwphotony #carnegiehall" in rendered
    assert "\n\n" in rendered  # blank line between caption and tags


# === ocr_program ===


def test_ocr_requires_at_least_one_image():
    with pytest.raises(ValueError, match="At least one image"):
        ocr_program.extract_program([])


def test_ocr_raises_on_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        ocr_program.extract_program([tmp_path / "does_not_exist.jpg"])


def test_ocr_returns_full_schema_with_defaults(sample_photo):
    fake_response = json.dumps(
        {
            "performers": [{"name": "X", "role": "soloist"}],
            "pieces": [{"composer": "Y", "title": "Z"}],
            # Intentionally omit organization_notes/program_notes/venue_notes/other
        }
    )
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        return_value=json.loads(fake_response),
    ):
        result = ocr_program.extract_program([sample_photo])

    # All schema keys must be present even if model omitted them
    for key in (
        "performers",
        "pieces",
        "organization_notes",
        "program_notes",
        "venue_notes",
        "other",
    ):
        assert key in result
    assert result["performers"][0]["name"] == "X"
    assert result["organization_notes"] == ""


def test_ocr_raises_when_response_not_object(sample_photo):
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        return_value=["not", "an", "object"],
    ):
        with pytest.raises(ClaudeError, match="Expected JSON object"):
            ocr_program.extract_program([sample_photo])


def test_ocr_accepts_heic_path_and_converts(tmp_path):
    """HEIC files should be auto-converted to JPEG before OCR."""
    heic = tmp_path / "program.heic"
    heic.write_bytes(b"fake heic bytes")  # extract_program only checks .exists()

    captured = {}

    def fake_convert(src, dest_dir):
        # Simulate sips: write a fake JPEG into the temp dir
        out = dest_dir / (src.stem + ".jpg")
        out.write_bytes(b"fake jpeg bytes")
        captured["src"] = src
        captured["dest"] = out
        return out

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None):
        captured["prompt"] = prompt
        captured["allowed_dirs"] = allowed_dirs
        captured["allowed_tools"] = allowed_tools
        return {"performers": [], "pieces": []}

    with patch("postroll.ai.ocr_program._convert_heic_to_jpeg", side_effect=fake_convert):
        with patch("postroll.ai.ocr_program.run_json_prompt", side_effect=fake_run_json):
            result = ocr_program.extract_program([heic])

    # Conversion was invoked on the HEIC file
    assert captured["src"] == heic
    # The prompt references the converted JPEG path, not the HEIC
    assert ".jpg" in captured["prompt"]
    assert "program.heic" not in captured["prompt"]
    assert isinstance(result, dict)


def test_ocr_passes_jpeg_unchanged(sample_photo):
    """Non-HEIC paths should pass through without conversion."""
    with patch("postroll.ai.ocr_program._convert_heic_to_jpeg") as mock_convert:
        with patch(
            "postroll.ai.ocr_program.run_json_prompt",
            return_value={"performers": [], "pieces": []},
        ):
            ocr_program.extract_program([sample_photo])
    mock_convert.assert_not_called()


@pytest.mark.skipif(sys.platform != "darwin", reason="sips is macOS-only")
def test_convert_heic_raises_when_sips_missing(tmp_path):
    """If sips isn't on PATH, conversion raises a clear error."""
    src = tmp_path / "x.heic"
    src.write_bytes(b"fake")
    with patch("postroll.ai.ocr_program.shutil.which", return_value=None):
        with pytest.raises(ClaudeError, match="sips.*not found"):
            ocr_program._convert_heic_to_jpeg(src, tmp_path)


# === generate_captions ===


def test_caption_raises_on_missing_photo(tmp_path):
    with pytest.raises(FileNotFoundError):
        generate_captions.generate_caption(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            day="sunday",
            photo_paths=[tmp_path / "missing.jpg"],
            program={},
        )


def test_caption_returns_normalized_dict(sample_photo):
    fake = {
        "caption": "  A specific moment from the second movement.  ",
        "hashtags": ["#dwphotony", "#carnegiehall", "#dcinyconcerts"],
        "alt_texts": ["  A conductor mid-phrase facing a choir.  "],
        "scene_labels": [None],
    }
    with patch(
        "postroll.ai.generate_captions.run_json_prompt", return_value=fake
    ):
        result = generate_captions.generate_caption(
            event="Sing Play",
            org="DCINY",
            venue="Carnegie Hall",
            date="2026-04-05",
            day="sunday",
            photo_paths=[sample_photo],
            program={"performers": [], "pieces": []},
        )
    assert result["caption"] == "A specific moment from the second movement."
    assert result["alt_texts"][0] == "A conductor mid-phrase facing a choir."
    assert result["hashtags"][0] == "#dwphotony"


def test_caption_passes_brand_voice_to_prompt(sample_photo):
    captured = {}

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None):
        captured["prompt"] = prompt
        captured["allowed_dirs"] = allowed_dirs
        captured["allowed_tools"] = allowed_tools
        return {"caption": "x", "hashtags": [], "alt_text": "x"}

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json
    ):
        generate_captions.generate_caption(
            event="Sing Play",
            org="DCINY",
            venue="Carnegie Hall",
            date="2026-04-05",
            day="sunday",
            photo_paths=[sample_photo],
            program={"performers": [], "pieces": []},
            skip_humanizer=True,
            skip_voice_pass=True,
        )

    prompt = captured["prompt"]
    assert "Dan Wright" in prompt  # brand voice loaded
    assert "Sing Play" in prompt
    assert "DCINY" in prompt
    assert "Carnegie Hall" in prompt
    assert "#dwphotony" in prompt  # hashtag rule restated
    # Permission flags wired through
    assert captured["allowed_tools"] == ["Read"]
    assert captured["allowed_dirs"] is not None


# === generate_blog ===


def test_blog_requires_at_least_one_photo():
    with pytest.raises(ValueError, match="No blog photos"):
        generate_blog.generate_blog(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            program={},
            photo_paths=[],
        )


def test_blog_returns_title_and_body(sample_photo):
    fake = {
        "title": "Mahler Resurrection at Carnegie Hall",
        "body": "Para 1.\n\n[PHOTO: conductor]\n\nPara 2.",
        "photo_count": 4,
    }
    with patch(
        "postroll.ai.generate_blog.run_json_prompt", return_value=fake
    ):
        result = generate_blog.generate_blog(
            event="Sing Play",
            org="DCINY",
            venue="Carnegie Hall",
            date="2026-04-05",
            program={
                "performers": [{"name": "Lauren Snouffer", "role": "soloist"}],
                "pieces": [{"composer": "Mahler", "title": "Symphony No. 2"}],
                "organization_notes": "DCINY presents...",
                "program_notes": "Mahler composed...",
            },
            photo_paths=[sample_photo] * 4,
        )
    assert result["title"] == "Mahler Resurrection at Carnegie Hall"
    assert "[PHOTO:" in result["body"]
    assert result["photo_count"] == 4


def test_blog_passes_program_notes_to_prompt(sample_photo):
    captured = {}

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None):
        captured["prompt"] = prompt
        return {"title": "x", "body": "x", "photo_count": 4}

    with patch(
        "postroll.ai.generate_blog.run_json_prompt", side_effect=fake_run_json
    ):
        generate_blog.generate_blog(
            event="Sing Play",
            org="DCINY",
            venue="Carnegie Hall",
            date="2026-04-05",
            program={
                "performers": [{"name": "Lauren Snouffer", "role": "soloist"}],
                "pieces": [
                    {"composer": "Mahler", "title": "Symphony No. 2", "notes": "Composed in 1894"}
                ],
                "organization_notes": "DCINY brings choirs to Carnegie Hall.",
                "program_notes": "The Resurrection symphony explores life and death.",
                "venue_notes": "Carnegie Hall opened in 1891.",
                "other": "Sponsored by anonymous donor.",
            },
            photo_paths=[sample_photo] * 4,
            skip_humanizer=True,
            skip_voice_pass=True,
        )

    prompt = captured["prompt"]
    # All OCR fields should reach the prompt
    assert "DCINY brings choirs to Carnegie Hall." in prompt
    assert "Resurrection symphony explores life and death." in prompt
    assert "Carnegie Hall opened in 1891." in prompt
    assert "Sponsored by anonymous donor." in prompt
    assert "Composed in 1894" in prompt
    # Brand voice loaded
    assert "Dan Wright" in prompt
