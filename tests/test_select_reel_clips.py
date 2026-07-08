"""Tests for the Friday clip reel's Stage 2: the Claude call that selects,
orders, and trims clips from Stage 1's usable set.

apply_selection() is the pure validate-and-clamp core (mirrors
select_reel_photos.py's index validate-and-dedup logic) and is tested
directly with hand-built fake Claude responses, no network or mocking
needed. select_reel_clips() is the thin orchestration wrapper (frame
extraction + prompt + run_json_prompt call); it's tested by monkeypatching
run_json_prompt, the same boundary test_ai_claude_client.py mocks at.
"""

from __future__ import annotations

import pytest

from postroll.ai.claude_client import ClaudeError
from postroll.ai.select_reel_clips import (
    MAX_CLIPS_TO_STAGE2,
    apply_selection,
    select_reel_clips,
)

CANDIDATES = [
    {"path": "/clips/a.mov", "duration": 8.0, "usable": True, "score": 40.0, "valid_trim": (1.0, 6.0)},
    {"path": "/clips/b.mov", "duration": 6.0, "usable": True, "score": 35.0, "valid_trim": (0.5, 5.0)},
    {"path": "/clips/c.mov", "duration": 7.0, "usable": True, "score": 30.0, "valid_trim": (2.0, 6.5)},
]


# ===================================================================
# apply_selection: pure validate-and-clamp (no network)
# ===================================================================

def test_valid_selection_passes_through_with_clamped_trim():
    data = {
        "selections": [
            {"clip_index": 1, "trim_in": 0.5, "trim_out": 5.0, "transition_after": "crossfade"},
            {"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut"},
        ],
        "rationale": "opens with the wide shot, closes on the soloist",
    }

    result = apply_selection(data, CANDIDATES)

    assert [s["clip_path"] for s in result["selections"]] == ["/clips/b.mov", "/clips/a.mov"]
    assert result["selections"][0]["transition_after"] == "crossfade"
    assert result["rationale"] == "opens with the wide shot, closes on the soloist"


def test_trim_window_outside_valid_range_is_clamped_not_trusted():
    # Claude proposes a trim that reaches outside clip 0's valid_trim (1.0, 6.0)
    # entirely: this must never survive uncapped, that's the whole point of
    # server-side clamping (a bad AI pick must be structurally impossible).
    data = {"selections": [{"clip_index": 0, "trim_in": 0.0, "trim_out": 9.0, "transition_after": "cut"}]}

    result = apply_selection(data, CANDIDATES)

    sel = result["selections"][0]
    assert sel["trim_in"] >= 1.0
    assert sel["trim_out"] <= 6.0


def test_inverted_trim_window_falls_back_to_full_valid_range():
    data = {"selections": [{"clip_index": 0, "trim_in": 5.0, "trim_out": 1.5, "transition_after": "cut"}]}

    result = apply_selection(data, CANDIDATES)

    sel = result["selections"][0]
    assert sel["trim_in"] == 1.0
    assert sel["trim_out"] == 6.0


def test_out_of_range_index_is_dropped():
    data = {"selections": [
        {"clip_index": 99, "trim_in": 0, "trim_out": 1, "transition_after": "cut"},
        {"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut"},
    ]}

    result = apply_selection(data, CANDIDATES)

    assert len(result["selections"]) == 1
    assert result["selections"][0]["clip_path"] == "/clips/a.mov"


def test_duplicate_index_keeps_only_first_occurrence():
    data = {"selections": [
        {"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut"},
        {"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "crossfade"},
    ]}

    result = apply_selection(data, CANDIDATES)

    assert len(result["selections"]) == 1
    assert result["selections"][0]["transition_after"] == "cut"


def test_invalid_transition_value_defaults_to_cut():
    data = {"selections": [{"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "dissolve"}]}

    result = apply_selection(data, CANDIDATES)

    assert result["selections"][0]["transition_after"] == "cut"


def test_missing_selections_key_raises():
    with pytest.raises(ClaudeError):
        apply_selection({"rationale": "no selections field"}, CANDIDATES)


def test_selections_not_a_list_raises():
    with pytest.raises(ClaudeError):
        apply_selection({"selections": "not a list"}, CANDIDATES)


def test_all_selections_invalid_raises_rather_than_returning_empty():
    # Every index is out of range: this must fail loud, not silently hand
    # Stage 3 an empty selection list to render nothing from.
    data = {"selections": [{"clip_index": 99, "trim_in": 0, "trim_out": 1, "transition_after": "cut"}]}
    with pytest.raises(ClaudeError):
        apply_selection(data, CANDIDATES)


def test_missing_rationale_defaults_to_empty_string():
    data = {"selections": [{"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut"}]}

    result = apply_selection(data, CANDIDATES)

    assert result["rationale"] == ""


# ===================================================================
# select_reel_clips: orchestration wrapper (run_json_prompt mocked)
# ===================================================================

def test_select_reel_clips_calls_claude_and_clamps_result(monkeypatch, tmp_path):
    captured = {}

    def fake_extract(path, times, count, out_dir, prefix):
        # Stand in for real ffmpeg frame extraction so this test needs no
        # ffmpeg and no real clip files.
        frames = []
        for i in range(count):
            f = out_dir / f"{prefix}{i}.png"
            f.write_bytes(b"fake")
            frames.append(f)
        return frames

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        captured["prompt"] = prompt
        captured["image_paths"] = image_paths
        captured["image_labels"] = image_labels
        return {
            "selections": [{"clip_index": 0, "trim_in": 0.0, "trim_out": 99.0, "transition_after": "cut"}],
            "rationale": "test rationale",
        }

    import postroll.ai.select_reel_clips as mod
    monkeypatch.setattr(mod, "_extract_representative_frames", fake_extract)
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    result = select_reel_clips(CANDIDATES, tmp_dir=tmp_path)

    assert result["rationale"] == "test rationale"
    # The out-of-range trim must still be clamped even through the full call.
    assert result["selections"][0]["trim_in"] == 1.0
    assert result["selections"][0]["trim_out"] == 6.0
    # image_labels must be 1:1 with image_paths (the exact contract
    # claude_client.run_json_prompt validates and feedback_image_filename_correlation
    # exists to enforce).
    assert len(captured["image_labels"]) == len(captured["image_paths"])
    assert captured["image_labels"][0] == "[clip 0, frame 0]"


def test_select_reel_clips_caps_candidates_at_max_clips_to_stage2(monkeypatch, tmp_path):
    many_candidates = [
        {"path": f"/clips/c{i}.mov", "duration": 5.0, "usable": True, "score": float(i), "valid_trim": (0.0, 5.0)}
        for i in range(MAX_CLIPS_TO_STAGE2 + 5)
    ]

    def fake_extract(path, times, count, out_dir, prefix):
        return [out_dir / f"{prefix}0.png" for _ in range(1)]

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        return {"selections": [{"clip_index": 0, "trim_in": 0.0, "trim_out": 5.0, "transition_after": "cut"}], "rationale": ""}

    import postroll.ai.select_reel_clips as mod
    monkeypatch.setattr(mod, "_extract_representative_frames", fake_extract)
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    result = select_reel_clips(many_candidates, tmp_dir=tmp_path)

    # Highest-scored candidate (score = MAX+4, the last one) must be the
    # survivor at index 0 once capped, proving the cap keeps the best-scored
    # clips rather than an arbitrary prefix.
    assert result["selections"][0]["clip_path"] == f"/clips/c{MAX_CLIPS_TO_STAGE2 + 4}.mov"


def test_select_reel_clips_filters_out_unusable_candidates(monkeypatch, tmp_path):
    mixed = CANDIDATES + [
        {"path": "/clips/bad.mov", "duration": 3.0, "usable": False, "score": 0.0, "valid_trim": None}
    ]

    def fake_extract(path, times, count, out_dir, prefix):
        assert path != "/clips/bad.mov", "an unusable clip must never reach frame extraction"
        return [out_dir / f"{prefix}0.png"]

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        return {"selections": [{"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut"}], "rationale": ""}

    import postroll.ai.select_reel_clips as mod
    monkeypatch.setattr(mod, "_extract_representative_frames", fake_extract)
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    select_reel_clips(mixed, tmp_dir=tmp_path)  # would AssertionError via fake_extract if it leaked through


def test_select_reel_clips_propagates_claude_error(monkeypatch, tmp_path):
    # Failure path: a Claude API failure must surface, not be swallowed into
    # an empty or fake-success selection.
    def fake_extract(path, times, count, out_dir, prefix):
        return [out_dir / f"{prefix}0.png"]

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        raise ClaudeError("Anthropic API error: overloaded")

    import postroll.ai.select_reel_clips as mod
    monkeypatch.setattr(mod, "_extract_representative_frames", fake_extract)
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    with pytest.raises(ClaudeError):
        select_reel_clips(CANDIDATES, tmp_dir=tmp_path)


def test_select_reel_clips_raises_with_no_usable_candidates(tmp_path):
    all_unusable = [{"path": "/x.mov", "duration": 3.0, "usable": False, "score": 0.0, "valid_trim": None}]
    with pytest.raises(ClaudeError):
        select_reel_clips(all_unusable, tmp_dir=tmp_path)
