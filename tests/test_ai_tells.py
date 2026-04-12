"""Tests for the AI tells loader and its integration with generators."""

from __future__ import annotations

import os
import time
from unittest.mock import patch

import pytest

from postroll.ai import ai_tells, generate_blog, generate_captions
from postroll.ai.ai_tells import (
    CACHE_MAX_AGE_DAYS,
    _is_cache_fresh,
    format_for_prompt,
    get_ai_tells_list,
)
from postroll.ai.claude_client import ClaudeError


# === Cache freshness ===


def test_cache_fresh_for_new_file(tmp_path):
    cache = tmp_path / "tells.md"
    cache.write_text("some patterns")
    assert _is_cache_fresh(cache) is True


def test_cache_not_fresh_when_missing(tmp_path):
    cache = tmp_path / "missing.md"
    assert _is_cache_fresh(cache) is False


def test_cache_not_fresh_when_old(tmp_path):
    cache = tmp_path / "tells.md"
    cache.write_text("old content")
    # Backdate the file by CACHE_MAX_AGE_DAYS + 1
    old_time = time.time() - (CACHE_MAX_AGE_DAYS + 1) * 86400
    os.utime(cache, (old_time, old_time))
    assert _is_cache_fresh(cache) is False


# === get_ai_tells_list ===


def test_get_ai_tells_returns_cache_when_fresh(tmp_path):
    """Cache hit — Wikipedia is NOT fetched."""
    cache = tmp_path / "tells.md"
    cache.write_text("cached AI tells content")

    with patch(
        "postroll.ai.ai_tells.run_prompt"
    ) as mock_run:
        result = get_ai_tells_list(cache)

    assert result == "cached AI tells content"
    mock_run.assert_not_called()


def test_get_ai_tells_fetches_when_cache_missing(tmp_path):
    """Cache miss — Claude is invoked with WebFetch and result is cached."""
    cache = tmp_path / "tells.md"
    fake_fetch_result = "## Vocabulary\n- delve\n- tapestry\n"

    with patch(
        "postroll.ai.ai_tells.run_prompt", return_value=fake_fetch_result
    ) as mock_run:
        result = get_ai_tells_list(cache)

    assert result == fake_fetch_result
    # Cache should now exist with the fetched content
    assert cache.exists()
    assert "delve" in cache.read_text()
    # Claude should have been called with WebFetch tool
    mock_run.assert_called_once()
    _, kwargs = mock_run.call_args
    assert kwargs.get("allowed_tools") == ["WebFetch"]


def test_get_ai_tells_refetches_when_stale(tmp_path):
    """Stale cache — refetch and overwrite."""
    cache = tmp_path / "tells.md"
    cache.write_text("stale content")
    old_time = time.time() - (CACHE_MAX_AGE_DAYS + 1) * 86400
    os.utime(cache, (old_time, old_time))

    fresh_content = "fresh AI tells content"
    with patch(
        "postroll.ai.ai_tells.run_prompt", return_value=fresh_content
    ) as mock_run:
        result = get_ai_tells_list(cache)

    assert result == fresh_content
    assert cache.read_text().strip() == fresh_content
    mock_run.assert_called_once()


def test_get_ai_tells_raises_on_empty_fetch(tmp_path):
    """An empty fetch result is an error, not a valid empty list."""
    cache = tmp_path / "tells.md"
    with patch("postroll.ai.ai_tells.run_prompt", return_value="   "):
        with pytest.raises(ClaudeError, match="empty content"):
            get_ai_tells_list(cache)


def test_get_ai_tells_creates_parent_directory(tmp_path):
    cache = tmp_path / "nested" / "deep" / "tells.md"
    with patch(
        "postroll.ai.ai_tells.run_prompt", return_value="content"
    ):
        get_ai_tells_list(cache)
    assert cache.exists()


def test_get_ai_tells_uses_wikipedia_url():
    """The fetch prompt must reference the canonical Wikipedia URL."""
    from postroll.ai.ai_tells import FETCH_PROMPT, WIKIPEDIA_URL

    assert "wikipedia.org" in WIKIPEDIA_URL
    assert "Signs_of_AI_writing" in WIKIPEDIA_URL
    assert WIKIPEDIA_URL in FETCH_PROMPT


# === format_for_prompt ===


def test_format_for_prompt_includes_self_review_instruction():
    """The injected section must tell Claude to self-review and revise."""
    formatted = format_for_prompt("- delve\n- tapestry")
    assert "delve" in formatted
    assert "tapestry" in formatted
    # Must instruct self-review
    assert "review" in formatted.lower()
    assert "revise" in formatted.lower()
    # Must say to return only the cleaned version
    assert "cleaned" in formatted.lower() or "final" in formatted.lower()


# === Blog integration ===


def test_blog_injects_ai_tells_when_cache_provided(sample_photo, tmp_path):
    """When ai_tells_cache is provided, the list reaches the prompt."""
    cache = tmp_path / "tells.md"
    cache.write_text("- delve\n- tapestry\n- pivotal moment")

    captured = {}

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None):
        captured["prompt"] = prompt
        return {"title": "x", "body": "x", "photo_count": 4}

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
            ai_tells_cache=cache,
        )

    prompt = captured["prompt"]
    assert "delve" in prompt
    assert "tapestry" in prompt
    assert "pivotal moment" in prompt
    # Self-review instruction injected
    assert "AI WRITING TELLS" in prompt or "ai writing tells" in prompt.lower()


def test_blog_omits_ai_tells_when_no_cache(sample_photo):
    """When ai_tells_cache is None, no list is injected."""
    captured = {}

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None):
        captured["prompt"] = prompt
        return {"title": "x", "body": "x", "photo_count": 4}

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
        )

    assert "AI WRITING TELLS" not in captured["prompt"]


# === Caption integration ===


def test_caption_injects_ai_tells_when_cache_provided(sample_photo, tmp_path):
    cache = tmp_path / "tells.md"
    cache.write_text("- delve\n- pivotal\n")

    captured = {}

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None):
        captured["prompt"] = prompt
        return {"caption": "x", "hashtags": [], "alt_text": "x"}

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json
    ):
        generate_captions.generate_caption(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            day="sunday",
            photo_path=sample_photo,
            program={"performers": [], "pieces": []},
            ai_tells_cache=cache,
        )

    prompt = captured["prompt"]
    assert "delve" in prompt
    assert "pivotal" in prompt
    assert "AI WRITING TELLS" in prompt or "ai writing tells" in prompt.lower()


def test_caption_omits_ai_tells_when_no_cache(sample_photo):
    captured = {}

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None):
        captured["prompt"] = prompt
        return {"caption": "x", "hashtags": [], "alt_text": "x"}

    with patch(
        "postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json
    ):
        generate_captions.generate_caption(
            event="E",
            org="O",
            venue="V",
            date="2026-04-05",
            day="sunday",
            photo_path=sample_photo,
            program={"performers": [], "pieces": []},
        )

    assert "AI WRITING TELLS" not in captured["prompt"]
