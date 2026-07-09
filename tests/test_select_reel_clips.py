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

import shutil
import subprocess
from pathlib import Path

import pytest

from postroll.ai.claude_client import ClaudeError
from postroll.ai.select_reel_clips import (
    CANDIDATE_DURATION_BUDGET,
    MAX_CANDIDATES_CEILING,
    apply_selection,
    select_reel_clips,
    _extract_representative_frames,
    _select_candidates,
)

HAVE_FFMPEG = shutil.which("ffmpeg") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg not installed")

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
    assert result["rationale"].startswith("opens with the wide shot, closes on the soloist")


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
    # A long enough valid_trim avoids the duration-shortfall note, isolating
    # the missing-rationale default this test actually checks.
    long_candidates = [
        {"path": "/clips/a.mov", "duration": 30.0, "usable": True, "score": 40.0, "valid_trim": (0.0, 25.0)},
    ]
    data = {"selections": [{"clip_index": 0, "trim_in": 0.0, "trim_out": 25.0, "transition_after": "cut"}]}

    result = apply_selection(data, long_candidates)

    assert result["rationale"] == ""


def test_short_total_duration_gets_a_visible_note_in_rationale():
    # Dan's feedback (2026-07-08): Stage 2 can undershoot its own stated
    # 20-30s target substantially while its rationale claims otherwise.
    # A miss this large must be visible in the review UI, not silent.
    long_candidates = [
        {"path": "/clips/a.mov", "duration": 10.0, "usable": True, "score": 40.0, "valid_trim": (0.0, 3.0)},
    ]
    data = {
        "selections": [{"clip_index": 0, "trim_in": 0.0, "trim_out": 3.0, "transition_after": "cut"}],
        "rationale": "quick highlight",
    }

    result = apply_selection(data, long_candidates)

    assert "quick highlight" in result["rationale"]
    assert "3s" in result["rationale"] or "3.0s" in result["rationale"]


def test_meeting_target_duration_leaves_rationale_unannotated():
    long_candidates = [
        {"path": "/clips/a.mov", "duration": 30.0, "usable": True, "score": 40.0, "valid_trim": (0.0, 25.0)},
    ]
    data = {
        "selections": [{"clip_index": 0, "trim_in": 0.0, "trim_out": 25.0, "transition_after": "cut"}],
        "rationale": "one long strong take",
    }

    result = apply_selection(data, long_candidates)

    assert result["rationale"] == "one long strong take"


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

    assert result["rationale"].startswith("test rationale")
    # The out-of-range trim must still be clamped even through the full call.
    assert result["selections"][0]["trim_in"] == 1.0
    assert result["selections"][0]["trim_out"] == 6.0
    # image_labels must be 1:1 with image_paths (the exact contract
    # claude_client.run_json_prompt validates and feedback_image_filename_correlation
    # exists to enforce).
    assert len(captured["image_labels"]) == len(captured["image_paths"])
    assert captured["image_labels"][0] == "[clip 0, frame 0]"


# ===================================================================
# _select_candidates: duration-budget-based candidate cap (pure, no network)
# ===================================================================

def test_select_candidates_stops_once_duration_budget_is_covered():
    # 10 clips at 10s valid_trim each: the budget (45s) is covered by the
    # 5th, so the 6th onward (lower-scored) must not be included.
    usable = [
        {"path": f"/clips/c{i}.mov", "score": float(10 - i), "valid_trim": (0.0, 10.0)}
        for i in range(10)
    ]

    candidates = _select_candidates(usable)

    assert len(candidates) == 5
    assert [c["path"] for c in candidates] == [f"/clips/c{i}.mov" for i in range(5)]


def test_select_candidates_respects_hard_ceiling_with_many_small_clips():
    # 50 tiny clips (1s each): the duration budget alone would allow far
    # more than MAX_CANDIDATES_CEILING, but the ceiling must still apply.
    usable = [
        {"path": f"/clips/c{i}.mov", "score": float(50 - i), "valid_trim": (0.0, 1.0)}
        for i in range(50)
    ]

    candidates = _select_candidates(usable)

    assert len(candidates) == MAX_CANDIDATES_CEILING


def test_select_candidates_always_includes_at_least_one_clip():
    # A single clip whose own span already exceeds the budget must still
    # be included, not dropped to an empty candidate list.
    usable = [{"path": "/clips/long.mov", "score": 10.0, "valid_trim": (0.0, CANDIDATE_DURATION_BUDGET + 20.0)}]

    candidates = _select_candidates(usable)

    assert len(candidates) == 1
    assert candidates[0]["path"] == "/clips/long.mov"


def test_select_candidates_adapts_to_available_footage_not_a_fixed_count(monkeypatch, tmp_path):
    # Real behavior check (2026-07-08, Dan's call): a week with plenty of
    # good, longer clips should offer Claude however many are needed to
    # cover the target duration with room to choose, not always exactly 8.
    many_candidates = [
        {"path": f"/clips/c{i}.mov", "duration": 5.0, "usable": True, "score": float(i), "valid_trim": (0.0, 5.0)}
        for i in range(30)
    ]

    def fake_extract(path, times, count, out_dir, prefix):
        return [out_dir / f"{prefix}0.png" for _ in range(1)]

    captured = {}

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        captured["count"] = len(image_paths)
        return {"selections": [{"clip_index": 0, "trim_in": 0.0, "trim_out": 5.0, "transition_after": "cut"}], "rationale": ""}

    import postroll.ai.select_reel_clips as mod
    monkeypatch.setattr(mod, "_extract_representative_frames", fake_extract)
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    result = select_reel_clips(many_candidates, tmp_dir=tmp_path)

    # 5s clips: budget (45s) covered by 9 clips (45/5), one frame each here.
    assert captured["count"] == 9
    # Highest-scored candidate (score=29) must still be the survivor.
    assert result["selections"][0]["clip_path"] == "/clips/c29.mov"


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


@needs_ffmpeg
def test_extracted_frames_are_jpeg_not_png(tmp_path):
    # Real bug found 2026-07-08: with only a few usable clips, Stage 2's
    # image payload stayed small enough to slip by, but once the clip
    # scorer fixes above raised real usable-clip counts to what production
    # actually needs, sending a full candidate batch of PNG frames
    # (claude_client.py keeps PNGs undownsized in size, only JPEGs get
    # recompressed smaller) hit a real 413 request_too_large from the
    # Anthropic API. PNG frames from real 4K clips run ~1.7MB each even
    # after Claude's own downscale step; JPEG at the same size is ~0.2MB.
    # Frames must be extracted as JPEG so claude_client.py's mimetype-based
    # downscale path actually shrinks them.
    clip = tmp_path / "clip.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", "testsrc=s=640x480:d=2:r=10", str(clip)],
        check=True,
    )

    frames = _extract_representative_frames(clip, (0.2, 1.8), 2, tmp_path, prefix="test_")

    assert frames, "no frames were extracted"
    for frame in frames:
        assert Path(frame).suffix.lower() in (".jpg", ".jpeg"), (
            f"{frame} is not a JPEG: PNG frames don't get recompressed "
            "smaller by claude_client.py's downscale step"
        )
