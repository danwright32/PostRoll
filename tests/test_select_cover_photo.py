"""Tests for the Instagram grid cover image Stage: the Claude call that picks
which candidate photo/frame becomes cover.png.

apply_cover_pick() is the pure validate core (mirrors select_reel_clips.py's
apply_selection) and is tested directly with hand-built fake Claude
responses, no network or mocking needed. select_cover_photo() is the thin
orchestration wrapper (staging + prompt + run_json_prompt call); it's tested
by monkeypatching run_json_prompt, the same boundary test_select_reel_clips.py
mocks at.

Unlike Friday's clip reel (which has a full before/after fallback when
Stage 2 fails), a cover-less reel is a real UX gap: select_cover_photo must
never raise on an unusable Claude response, it must fall back to a
deterministic first-candidate pick instead.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from postroll.ai.claude_client import ClaudeError
from postroll.ai.select_cover_photo import apply_cover_pick, select_cover_photo

CANDIDATES = [
    {"path": "/photos/a.jpg"},
    {"path": "/photos/b.jpg"},
    {"path": "/photos/c.jpg"},
]


# ===================================================================
# apply_cover_pick: pure validate (no network)
# ===================================================================

def test_valid_index_returns_path_and_rationale():
    data = {"index": 1, "rationale": "sharp soloist close-up"}

    result = apply_cover_pick(data, CANDIDATES)

    assert result == {"index": 1, "path": "/photos/b.jpg", "rationale": "sharp soloist close-up"}


def test_out_of_range_index_raises():
    with pytest.raises(ClaudeError):
        apply_cover_pick({"index": 99, "rationale": "x"}, CANDIDATES)


def test_negative_index_raises():
    with pytest.raises(ClaudeError):
        apply_cover_pick({"index": -1, "rationale": "x"}, CANDIDATES)


def test_non_int_index_raises():
    with pytest.raises(ClaudeError):
        apply_cover_pick({"index": "1", "rationale": "x"}, CANDIDATES)


def test_missing_index_key_raises():
    with pytest.raises(ClaudeError):
        apply_cover_pick({"rationale": "no index field"}, CANDIDATES)


def test_non_dict_response_raises():
    with pytest.raises(ClaudeError):
        apply_cover_pick("not a dict", CANDIDATES)


def test_missing_rationale_defaults_to_empty_string():
    result = apply_cover_pick({"index": 0}, CANDIDATES)

    assert result["rationale"] == ""


def test_non_string_rationale_defaults_to_empty_string():
    result = apply_cover_pick({"index": 0, "rationale": 42}, CANDIDATES)

    assert result["rationale"] == ""


# ===================================================================
# select_cover_photo: orchestration wrapper (run_json_prompt mocked)
# ===================================================================

def _make_photos(tmp_path: Path, count: int) -> list[dict]:
    paths = []
    for i in range(count):
        p = tmp_path / f"photo{i}.jpg"
        Image.new("RGB", (40, 60), (i * 10 % 255, 0, 0)).save(p)
        paths.append({"path": str(p)})
    return paths


def test_select_cover_photo_calls_claude_and_returns_validated_pick(monkeypatch, tmp_path):
    candidates = _make_photos(tmp_path, 3)
    captured = {}

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        captured["image_paths"] = image_paths
        captured["image_labels"] = image_labels
        return {"index": 2, "rationale": "test rationale"}

    import postroll.ai.select_cover_photo as mod
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    result = select_cover_photo(candidates)

    assert result["index"] == 2
    assert result["path"] == candidates[2]["path"]
    assert result["rationale"] == "test rationale"
    # image_labels must be 1:1 with image_paths (feedback_image_filename_correlation).
    assert len(captured["image_labels"]) == len(captured["image_paths"]) == 3


def test_select_cover_photo_single_candidate_skips_claude_call(monkeypatch, tmp_path):
    candidates = _make_photos(tmp_path, 1)

    def fake_run_json_prompt(*args, **kwargs):
        raise AssertionError("run_json_prompt must not be called for a single candidate")

    import postroll.ai.select_cover_photo as mod
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    result = select_cover_photo(candidates)

    assert result["index"] == 0
    assert result["path"] == candidates[0]["path"]


def test_select_cover_photo_falls_back_to_first_candidate_when_response_unusable(monkeypatch, tmp_path):
    candidates = _make_photos(tmp_path, 3)

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        return {"index": 99, "rationale": "out of range, unusable"}

    import postroll.ai.select_cover_photo as mod
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    result = select_cover_photo(candidates)  # must not raise

    assert result["index"] == 0
    assert result["path"] == candidates[0]["path"]


def test_select_cover_photo_falls_back_when_claude_call_raises(monkeypatch, tmp_path):
    candidates = _make_photos(tmp_path, 3)

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        raise ClaudeError("Anthropic API error: overloaded")

    import postroll.ai.select_cover_photo as mod
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    result = select_cover_photo(candidates)  # must not raise

    assert result["index"] == 0
    assert result["path"] == candidates[0]["path"]


def test_select_cover_photo_raises_with_no_candidates():
    with pytest.raises(ClaudeError):
        select_cover_photo([])
