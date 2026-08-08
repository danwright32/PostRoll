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


def test_ocr_retry_succeeds_when_first_call_returns_list(sample_photo):
    """If Claude returns a list initially but a dict on retry, OCR succeeds."""
    # Retry returns a dict with pieces and program_notes already populated, so
    # neither pieces nor prose fallback fires.
    responses = [
        ["array instead of object"],
        {
            "performers": [{"name": "A", "role": "conductor"}],
            "pieces": [{"composer": "Bach", "title": "Cello Suite"}],
            "program_notes": "Notes about the works.",
        },
    ]
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        side_effect=responses,
    ) as mock_run:
        result = ocr_program.extract_program([sample_photo])

    assert mock_run.call_count == 2
    # Retry prompt should include the reinforced preamble
    retry_prompt = mock_run.call_args_list[1][0][0]
    assert "MUST be a single JSON object" in retry_prompt
    assert result["performers"][0]["name"] == "A"


def test_ocr_salvages_pieces_list_when_retry_also_returns_list(sample_photo):
    """When Claude returns a list both times and the items look like pieces,
    wrap them under 'pieces' rather than failing — performer info can come
    from the event URL or be filled in by hand."""
    pieces_list = [
        {"composer": "Bach", "title": "Mass in B Minor", "movements": []},
        {"composer": "Mozart", "title": "Requiem", "movements": []},
    ]
    # 1st: main call returns list. 2nd: retry returns list. After salvage,
    # data has pieces but no performers → performers fallback fires (3rd call).
    # Then program_notes is empty, so prose fallback fires (4th call).
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        side_effect=[pieces_list, pieces_list, [], {}],
    ):
        result = ocr_program.extract_program([sample_photo])

    assert result["performers"] == []
    assert len(result["pieces"]) == 2
    assert result["pieces"][0]["title"] == "Mass in B Minor"


def test_ocr_pieces_fallback_runs_when_main_returns_empty_pieces(sample_photo):
    """When the main OCR call returns a dict with pieces=[] but the program
    clearly contains works, a focused pieces-only call should recover them."""
    main_response = {
        "performers": [{"name": "Jane", "role": "conductor"}],
        "pieces": [],
        "scenes": [],
        "program_notes": "Some notes about the works.",
    }
    pieces_only_response = [
        {"composer": "Bach", "title": "Mass in B Minor", "movements": []},
        {"composer": "Mozart", "title": "Requiem", "movements": []},
    ]
    # Performers is non-empty in main_response so only the pieces fallback runs
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        side_effect=[main_response, pieces_only_response],
    ) as mock_run:
        result = ocr_program.extract_program([sample_photo])

    assert mock_run.call_count == 2
    # Second call should be the focused pieces prompt
    fallback_prompt = mock_run.call_args_list[1][0][0]
    assert "ONLY the list of" in fallback_prompt
    assert len(result["pieces"]) == 2
    assert result["pieces"][0]["title"] == "Mass in B Minor"
    # Other fields from the main call must be preserved
    assert result["program_notes"] == "Some notes about the works."


def test_ocr_pieces_fallback_skipped_when_main_already_has_pieces(sample_photo):
    """Don't run the pieces fallback if the main call already returned pieces.
    Performers and program_notes are also populated so no fallback runs —
    only one call total.
    """
    main_response = {
        "performers": [{"name": "A", "role": "conductor"}],
        "pieces": [{"composer": "Bach", "title": "Cello Suite"}],
        "program_notes": "Some notes.",
    }
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        return_value=main_response,
    ) as mock_run:
        result = ocr_program.extract_program([sample_photo])

    assert mock_run.call_count == 1
    assert len(result["pieces"]) == 1


def test_ocr_performers_fallback_runs_when_main_returns_empty_performers(sample_photo):
    """When the main OCR call has pieces but no performers, the focused
    performers-only call should recover them — useful for program-notes
    booklets where performers are named in prose."""
    main_response = {
        "performers": [],
        "pieces": [{"composer": "Bach", "title": "Cello Suite"}],
        "program_notes": "Notes.",
    }
    performers_only_response = [
        {"name": "Kathryn E. Schneider", "role": "conductor", "voice_or_instrument": None},
        {"name": "Matthew V. Grieco", "role": "accompanist", "voice_or_instrument": "piano"},
    ]
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        side_effect=[main_response, performers_only_response],
    ) as mock_run:
        result = ocr_program.extract_program([sample_photo])

    assert mock_run.call_count == 2
    fallback_prompt = mock_run.call_args_list[1][0][0]
    assert "ONLY the people and" in fallback_prompt
    assert len(result["performers"]) == 2
    assert result["performers"][0]["name"] == "Kathryn E. Schneider"


def test_ocr_prose_fallback_runs_when_program_notes_empty(sample_photo):
    """When pieces are present but prose fields are empty, recover them via
    the focused prose-only call."""
    main_response = {
        "performers": [{"name": "A", "role": "conductor"}],
        "pieces": [{"composer": "Bach", "title": "Cello Suite"}],
        "program_notes": "",
    }
    prose_response = {
        "program_notes": "A long paragraph about the works.",
        "organization_notes": "About the choir.",
        "venue_notes": "",
        "production_details": "",
        "other": "",
    }
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        side_effect=[main_response, prose_response],
    ) as mock_run:
        result = ocr_program.extract_program([sample_photo])

    assert mock_run.call_count == 2
    assert result["program_notes"] == "A long paragraph about the works."
    assert result["organization_notes"] == "About the choir."


def test_ocr_prose_fallback_skipped_when_no_pieces(sample_photo):
    """If there are no pieces at all, the prose fallback shouldn't burn a
    call — the document is probably not a real program."""
    main_response = {
        "performers": [{"name": "A", "role": "conductor"}],
        "pieces": [],
        "program_notes": "",
    }
    # Only the main call + pieces fallback (1 + 1 = 2). No prose call.
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        side_effect=[main_response, []],
    ) as mock_run:
        ocr_program.extract_program([sample_photo])

    assert mock_run.call_count == 2


def test_ocr_prose_fallback_does_not_overwrite_existing_fields(sample_photo):
    """If the main call did populate venue_notes, the prose fallback's
    venue_notes value must NOT clobber it."""
    main_response = {
        "performers": [{"name": "A", "role": "conductor"}],
        "pieces": [{"composer": "Bach", "title": "Cello Suite"}],
        "program_notes": "",
        "venue_notes": "Original venue notes from main pass.",
    }
    prose_response = {
        "program_notes": "Fallback program notes.",
        "venue_notes": "Different fallback venue notes.",
    }
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        side_effect=[main_response, prose_response],
    ):
        result = ocr_program.extract_program([sample_photo])

    assert result["program_notes"] == "Fallback program notes."
    # Main pass value preserved
    assert result["venue_notes"] == "Original venue notes from main pass."


def test_ocr_performers_fallback_unwraps_dict_response():
    """If the focused performers call returns {performers: [...]}, unwrap it."""
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        return_value={"performers": [{"name": "X", "role": "soloist"}]},
    ):
        result = ocr_program._extract_performers_only(["/fake/path.jpg"])
    assert len(result) == 1
    assert result[0]["name"] == "X"


def test_ocr_pieces_fallback_unwraps_dict_response():
    """If the focused pieces call returns {pieces: [...]} instead of a bare
    array, _extract_pieces_only should unwrap it."""
    with patch(
        "postroll.ai.ocr_program.run_json_prompt",
        return_value={"pieces": [{"composer": "X", "title": "Y"}]},
    ):
        result = ocr_program._extract_pieces_only(["/fake/path.jpg"])
    assert len(result) == 1
    assert result[0]["title"] == "Y"


def test_salvage_list_response_routes_by_item_shape():
    """Unit test for the salvage helper: it should pick the right schema key
    based on what fields the array items have."""
    pieces = [{"title": "X", "composer": "Y"}]
    performers = [{"name": "X", "role": "soloist"}]
    scenes = [{"name": "Act I", "visual_cues": "spotlight"}]

    assert ocr_program._salvage_list_response(pieces) == {"pieces": pieces}
    assert ocr_program._salvage_list_response(performers) == {"performers": performers}
    assert ocr_program._salvage_list_response(scenes) == {"scenes": scenes}
    assert ocr_program._salvage_list_response([]) == {}
    assert ocr_program._salvage_list_response(["just", "strings"]) == {}


def test_ocr_accepts_heic_path_and_converts(tmp_path):
    """HEIC files should be auto-converted to JPEG before OCR."""
    heic = tmp_path / "program.heic"
    heic.write_bytes(b"fake heic bytes")  # extract_program only checks .exists()

    captured = {}

    def fake_convert(src, dest_dir, prefix=""):
        # Simulate sips: write a fake JPEG into the temp dir
        out = dest_dir / f"{prefix}{src.stem}.jpg"
        out.write_bytes(b"fake jpeg bytes")
        captured["src"] = src
        captured["dest"] = out
        captured["prefix"] = prefix
        return out

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        captured["allowed_dirs"] = allowed_dirs
        captured["allowed_tools"] = allowed_tools
        return {"performers": [], "pieces": []}

    with patch("postroll.ai.ocr_program._convert_heic_to_jpeg", side_effect=fake_convert):
        with patch("postroll.ai.ocr_program.run_json_prompt", side_effect=fake_run_json):
            result = ocr_program.extract_program([heic])

    # Conversion was invoked on the HEIC file
    assert captured["src"] == heic
    # Staged name carries the indexed prefix like plain copies do, so prefix
    # stripping recovers the original filename downstream
    assert captured["prefix"] == "000_"
    assert captured["dest"].name == "000_program.jpg"
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

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
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


def test_caption_clip_reel_post_type_gets_event_level_framing(sample_photo):
    # Phase 3 (#134): clip_reel is a new post_type for the Friday auto-cut
    # reel. Exercises the real generate_caption prompt-building path (not a
    # mocked generate_caption) so a KeyError or missing-framing regression
    # in POST_TYPE_FRAMING/EVENT_LEVEL_POST_TYPES/ALT_TEXT_INSTRUCTION would
    # fail this test, not just silently fall back to default framing.
    captured = {}

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        return {"caption": "x", "hashtags": [], "alt_texts": ["x"]}

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json
    ):
        generate_captions.generate_caption(
            event="Sing Play",
            org="DCINY",
            venue="Carnegie Hall",
            date="2026-04-05",
            day="friday",
            photo_paths=[sample_photo],
            program={"performers": [], "pieces": []},
            post_type="clip_reel",
            skip_humanizer=True,
            skip_voice_pass=True,
        )

    prompt = captured["prompt"]
    # The clip_reel-specific framing text made it into the real prompt.
    assert "auto-cut highlight reel" in prompt
    # Event-level scope rule applies (not the single-subject one): a
    # highlight reel spans multiple clips, not one frame.
    assert "SINGLE-SUBJECT" not in prompt
    # scroll_reel's unified-narrative alt text instruction is reused.
    assert "UNIFIED NARRATIVE" in prompt


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
        "body": "It's para one.\n\n[PHOTO: conductor]\n\nThat's para two.",
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
    # Title is deterministic: "{event} at {venue}".
    assert result["title"] == "Sing Play at Carnegie Hall"
    assert "[PHOTO:" in result["body"]
    assert result["photo_count"] == 4


def test_blog_passes_program_notes_to_prompt(sample_photo):
    captured = {}

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None, image_paths=None, image_labels=None, **kwargs):
        captured["prompt"] = prompt
        return {"title": "x", "body": "I'm here.", "photo_count": 4}

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


# === deterministic name backstop ===

def test_fix_wrong_names_corrects_first_name_against_program():
    program = {
        "performers": [],
        "production_details": "Conductors: Nicole Becker, Kate Logan.",
    }
    body = "conductor Beth Becker's gestures stayed small. Kate Logan sang."
    fixed = generate_blog._fix_wrong_names(body, program)
    # Wrong first name corrected; correct full name left alone; possessive kept.
    assert "Nicole Becker's" in fixed
    assert "Beth" not in fixed
    assert "Kate Logan" in fixed


def test_fix_wrong_names_leaves_venue_names_alone():
    """A performer surnamed like a venue word must not rewrite the venue:
    'Alice Tully Hall' is a capitalized run, not a hallucinated name."""
    program = {
        "performers": [{"name": "Grace Tully"}],
        "production_details": "",
    }
    body = "The recital filled Alice Tully Hall with sound. Grace Tully bowed."
    fixed = generate_blog._fix_wrong_names(body, program)
    assert "Alice Tully Hall" in fixed
    assert "Grace Tully bowed" in fixed


def test_fix_wrong_names_leaves_place_names_after_prepositions():
    program = {
        "performers": [{"name": "Jordan York"}],
        "production_details": "",
    }
    body = "The choir is based in New York. Jordan York conducted."
    fixed = generate_blog._fix_wrong_names(body, program)
    assert "in New York." in fixed
    assert "Jordan York conducted" in fixed


def test_fix_wrong_names_still_corrects_after_guards():
    """The guards must not break the actual correction path."""
    program = {
        "performers": [{"name": "Jordan York"}],
        "production_details": "",
    }
    body = "The program credits Steven York for the arrangement."
    fixed = generate_blog._fix_wrong_names(body, program)
    assert "Jordan York" in fixed
    assert "Steven" not in fixed


def test_fix_wrong_names_skips_three_part_names():
    program = {
        "performers": [{"name": "Other Jane"}],
        "production_details": "",
    }
    body = "Soloist Mary Jane Smith stepped forward."
    fixed = generate_blog._fix_wrong_names(body, program)
    assert "Mary Jane Smith" in fixed


# === per-paragraph contraction backstop ===

def test_fix_missing_contractions_rewords_only_offending_paragraph():
    body = (
        "A frame with no contraction at all.\n\n"
        "[PHOTO: x.jpg | alt]\n\n"
        "It's already fine here."
    )
    # Only the first paragraph lacks a contraction; it's reworded per-paragraph.
    with patch(
        "postroll.ai.generate_blog.run_prompt",
        return_value="A frame that's got one now.",
    ):
        out = generate_blog._fix_missing_contractions(body)
    assert "that's got one now" in out
    assert "[PHOTO: x.jpg | alt]" in out      # photo marker untouched
    assert "It's already fine here." in out   # clean paragraph untouched


def test_fix_missing_contractions_no_call_when_all_have_contractions():
    body = "It's fine.\n\nThat's also fine."
    with patch("postroll.ai.generate_blog.run_prompt") as m:
        out = generate_blog._fix_missing_contractions(body)
    m.assert_not_called()
    assert out == body


# === per-paragraph second-person backstop ===

def test_second_person_offenders_exclude_cta_and_quotes():
    body = (
        "You could hear the hall settle.\n\n"
        '"You were wonderful," the director told the cast.\n\n'
        "[PHOTO: a.jpg | alt]\n\n"
        "If you're planning a season announcement, get in touch."
    )
    offenders = generate_blog._paragraphs_with_second_person(body)
    # Only the first paragraph violates: the quote is speech and the final
    # prose paragraph is the CTA, which may address the reader.
    assert offenders == ["You could hear the hall settle."]


def test_fix_second_person_rewords_only_offending_paragraph():
    body = (
        "You could hear the hall settle.\n\n"
        "If you're planning a season announcement, get in touch."
    )
    with patch(
        "postroll.ai.generate_blog.run_prompt",
        return_value="I heard the hall settle.",
    ):
        out = generate_blog._fix_second_person(body)
    assert "I heard the hall settle." in out
    assert "If you're planning a season announcement" in out


def test_fix_second_person_no_call_when_clean():
    body = "The hall settled.\n\nIf you're planning a shoot, get in touch."
    with patch("postroll.ai.generate_blog.run_prompt") as m:
        out = generate_blog._fix_second_person(body)
    m.assert_not_called()
    assert out == body
