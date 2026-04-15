"""Tests for the learn_from_edits module."""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import learn_from_edits
from postroll.ai.learn_from_edits import learn_from_edits as _learn


# === learn_from_edits function ===


def test_returns_null_when_no_edits():
    result = _learn(brand_voice="Dan's voice.", edits=[])
    assert result == {"suggestion": None}


def test_returns_null_when_captions_unchanged():
    result = _learn(
        brand_voice="Dan's voice.",
        edits=[
            {"day": "sunday", "original_caption": "same text", "approved_caption": "same text"}
        ],
    )
    assert result == {"suggestion": None}


def test_calls_claude_when_edits_differ():
    calls: list[str] = []

    def fake_run_json(prompt, timeout=120, **kwargs):
        calls.append(prompt)
        return {"suggestion": "Don't open with a performer's name."}

    with patch("postroll.ai.learn_from_edits.run_json_prompt", side_effect=fake_run_json):
        result = _learn(
            brand_voice="Brand voice content here.",
            edits=[
                {
                    "day": "sunday",
                    "original_caption": "Maria sang the aria with clarity.",
                    "approved_caption": "The aria opened cleanly, Maria at the piano.",
                },
            ],
        )

    assert len(calls) == 1
    assert "Maria sang" in calls[0]
    assert "Brand voice content here." in calls[0]
    assert result == {"suggestion": "Don't open with a performer's name."}


def test_returns_null_when_claude_returns_null():
    def fake_run_json(prompt, timeout=120, **kwargs):
        return {"suggestion": None}

    with patch("postroll.ai.learn_from_edits.run_json_prompt", side_effect=fake_run_json):
        result = _learn(
            brand_voice="Brand voice.",
            edits=[
                {"day": "monday", "original_caption": "X", "approved_caption": "Y"}
            ],
        )

    assert result == {"suggestion": None}


def test_skips_pairs_with_empty_fields():
    calls: list[str] = []

    def fake_run_json(prompt, timeout=120, **kwargs):
        calls.append(prompt)
        return {"suggestion": "Some rule."}

    with patch("postroll.ai.learn_from_edits.run_json_prompt", side_effect=fake_run_json):
        _learn(
            brand_voice="Voice.",
            edits=[
                {"day": "sunday", "original_caption": "", "approved_caption": "Approved text."},
                {"day": "monday", "original_caption": "Generated text.", "approved_caption": ""},
                {"day": "tuesday", "original_caption": "A", "approved_caption": "B"},
            ],
        )

    # Only the tuesday pair (both non-empty, different) should reach Claude
    assert len(calls) == 1
    assert "tuesday" in calls[0].lower() or "A" in calls[0]


def test_multiple_edited_days_all_included():
    calls: list[str] = []

    def fake_run_json(prompt, timeout=120, **kwargs):
        calls.append(prompt)
        return {"suggestion": "Something new."}

    with patch("postroll.ai.learn_from_edits.run_json_prompt", side_effect=fake_run_json):
        _learn(
            brand_voice="Voice.",
            edits=[
                {"day": "sunday", "original_caption": "Gen1", "approved_caption": "App1"},
                {"day": "monday", "original_caption": "Gen2", "approved_caption": "App2"},
            ],
        )

    # Both pairs end up in a single Claude call
    assert len(calls) == 1
    assert "Gen1" in calls[0] and "App1" in calls[0]
    assert "Gen2" in calls[0] and "App2" in calls[0]
