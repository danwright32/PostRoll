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
    # Enough cuts of enough length to avoid both the duration-shortfall and
    # cut-count notes, isolating the missing-rationale default this test
    # actually checks.
    long_candidates = [
        {"path": f"/clips/r{i}.mov", "duration": 4.0, "usable": True, "score": 40.0, "valid_trim": (0.0, 2.5)}
        for i in range(10)
    ]
    data = {"selections": [
        {"clip_index": i, "trim_in": 0.0, "trim_out": 2.5, "transition_after": "cut"}
        for i in range(10)
    ]}

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
    # 10 cuts at 2.5s (25s total) meet both the duration target and the
    # cut-count target, so no note of either kind may be appended.
    long_candidates = [
        {"path": f"/clips/r{i}.mov", "duration": 4.0, "usable": True, "score": 40.0, "valid_trim": (0.0, 2.5)}
        for i in range(10)
    ]
    data = {
        "selections": [
            {"clip_index": i, "trim_in": 0.0, "trim_out": 2.5, "transition_after": "cut"}
            for i in range(10)
        ],
        "rationale": "steady build to the finale",
    }

    result = apply_selection(data, long_candidates)

    assert result["rationale"] == "steady build to the finale"


# ===================================================================
# Phase 0 crop plumbing (issue #149): crop_x / crop_y / crop_confidence
# on every selection, defaulting to today's centered crop. No behavior
# change yet; later phases build the prompt, gate wiring, and rendering
# on these fields.
# ===================================================================

def test_crop_fields_default_to_centered_when_missing():
    # Today's responses carry no crop fields at all: every selection must
    # still come back with the centered-crop defaults, never a KeyError
    # downstream.
    data = {"selections": [{"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut"}]}

    result = apply_selection(data, CANDIDATES)

    sel = result["selections"][0]
    assert sel["crop_x"] == 0.0
    assert sel["crop_y"] == 0.0
    assert sel["crop_confidence"] == "low"


def test_valid_crop_fields_pass_through():
    data = {"selections": [{
        "clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut",
        "crop_x": 0.4, "crop_y": -0.25, "crop_confidence": "high",
    }]}

    result = apply_selection(data, CANDIDATES)

    sel = result["selections"][0]
    assert sel["crop_x"] == 0.4
    assert sel["crop_y"] == -0.25
    assert sel["crop_confidence"] == "high"


def test_out_of_range_crop_values_are_clamped():
    # CropOffset convention (Event.swift): x/y live in [-1, 1]. A value
    # outside that range is clamped, same policy as trim windows.
    data = {"selections": [{
        "clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut",
        "crop_x": 3.0, "crop_y": -9.0, "crop_confidence": "high",
    }]}

    result = apply_selection(data, CANDIDATES)

    sel = result["selections"][0]
    assert sel["crop_x"] == 1.0
    assert sel["crop_y"] == -1.0


def test_malformed_crop_values_default_safely_without_failing_selection():
    # Garbage crop data must never fail the whole selection: the crop is
    # an enhancement, the cut itself is the product.
    data = {"selections": [{
        "clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut",
        "crop_x": "left", "crop_y": None, "crop_confidence": "medium",
    }]}

    result = apply_selection(data, CANDIDATES)

    sel = result["selections"][0]
    assert sel["crop_x"] == 0.0
    assert sel["crop_y"] == 0.0
    assert sel["crop_confidence"] == "low"


def test_non_string_crop_confidence_defaults_to_low():
    data = {"selections": [{
        "clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut",
        "crop_confidence": 42,
    }]}

    result = apply_selection(data, CANDIDATES)

    assert result["selections"][0]["crop_confidence"] == "low"


# ===================================================================
# Phase 1 pacing (issue #150): the prompt asks for the measured CapCut
# cadence, and a cut count that comes back too low gets a visible
# rationale note (mirroring the duration-shortfall note), never a
# silent reshape of the selection.
# ===================================================================

def _pacing_candidates(count: int, span: float) -> list[dict]:
    return [
        {"path": f"/clips/p{i}.mov", "duration": span + 2.0, "usable": True,
         "score": float(count - i), "valid_trim": (0.0, span)}
        for i in range(count)
    ]


def test_few_cuts_get_a_visible_note_in_rationale():
    # 5 cuts at 5s each: total duration (25s) is inside target, so any
    # note must be about the cut count, not duration.
    candidates = _pacing_candidates(5, 5.0)
    data = {
        "selections": [
            {"clip_index": i, "trim_in": 0.0, "trim_out": 5.0, "transition_after": "cut"}
            for i in range(5)
        ],
        "rationale": "energetic cut",
    }

    result = apply_selection(data, candidates)

    assert "energetic cut" in result["rationale"]
    assert "5 cuts" in result["rationale"]


def test_enough_cuts_leave_rationale_unannotated():
    # 10 cuts at 2.5s each (25s total): both duration and cut count meet
    # target, rationale must come back exactly as given.
    candidates = _pacing_candidates(10, 2.5)
    data = {
        "selections": [
            {"clip_index": i, "trim_in": 0.0, "trim_out": 2.5, "transition_after": "cut"}
            for i in range(10)
        ],
        "rationale": "punchy montage",
    }

    result = apply_selection(data, candidates)

    assert result["rationale"] == "punchy montage"


def test_duration_and_cut_count_notes_can_coexist():
    # 3 cuts at 2s each (6s total): both shortfalls apply and both notes
    # must survive in the rationale, neither clobbering the other.
    candidates = _pacing_candidates(3, 2.0)
    data = {
        "selections": [
            {"clip_index": i, "trim_in": 0.0, "trim_out": 2.0, "transition_after": "cut"}
            for i in range(3)
        ],
        "rationale": "short",
    }

    result = apply_selection(data, candidates)

    assert "short" in result["rationale"]
    assert "6.0s" in result["rationale"] or "6s" in result["rationale"]
    assert "3 cuts" in result["rationale"]


def test_selection_prompt_states_cadence_targets(monkeypatch, tmp_path):
    from postroll.ai.select_reel_clips import (
        TARGET_CLIP_SECONDS_MAX,
        TARGET_CLIP_SECONDS_MIN,
        TARGET_CUT_COUNT,
    )

    captured = {}

    def fake_extract(path, times, count, out_dir, prefix):
        return [out_dir / f"{prefix}0.png"]

    def fake_run_json_prompt(prompt, *, timeout, image_paths, image_labels, **kwargs):
        captured["prompt"] = prompt
        return {"selections": [{"clip_index": 0, "trim_in": 1.0, "trim_out": 6.0, "transition_after": "cut"}], "rationale": ""}

    import postroll.ai.select_reel_clips as mod
    monkeypatch.setattr(mod, "_extract_representative_frames", fake_extract)
    monkeypatch.setattr(mod, "run_json_prompt", fake_run_json_prompt)

    select_reel_clips(CANDIDATES, tmp_dir=tmp_path)

    # The cadence numbers must reach the prompt from the named constants,
    # so a recalibration never leaves stale prose behind.
    assert str(TARGET_CUT_COUNT) in captured["prompt"]
    assert f"{TARGET_CLIP_SECONDS_MIN:.1f}" in captured["prompt"]
    assert f"{TARGET_CLIP_SECONDS_MAX:.1f}" in captured["prompt"]


def test_select_candidates_supplies_enough_clips_for_target_cut_count():
    # 30 clips at 10s valid_trim each: the 45s duration budget alone would
    # stop at 5 candidates, but 12-13 cuts can't come out of 5 clips (each
    # clip is used at most once), so the pacing floor must keep supplying
    # candidates.
    from postroll.ai.select_reel_clips import MIN_CANDIDATES_FOR_PACING

    usable = [
        {"path": f"/clips/c{i}.mov", "score": float(30 - i), "valid_trim": (0.0, 10.0)}
        for i in range(30)
    ]

    candidates = _select_candidates(usable)

    assert len(candidates) == MIN_CANDIDATES_FOR_PACING
    # Still the highest-scored clips, in rank order.
    assert [c["path"] for c in candidates] == [f"/clips/c{i}.mov" for i in range(MIN_CANDIDATES_FOR_PACING)]


def test_select_candidates_floor_is_capped_by_available_clips():
    # Only 4 usable clips: the floor must not invent candidates.
    usable = [
        {"path": f"/clips/c{i}.mov", "score": float(4 - i), "valid_trim": (0.0, 10.0)}
        for i in range(4)
    ]

    candidates = _select_candidates(usable)

    assert len(candidates) == 4


# ===================================================================
# Hard motion gate (issue #149): the code-level check that a tight crop
# is only ever attempted on a calm shot Claude is confident about.
# Nothing calls this yet (Phase 2 wires it up); Phase 0 fixes the rule.
# ===================================================================

def test_crop_allowed_requires_high_confidence_and_low_motion():
    from postroll.ai.select_reel_clips import MAX_CROP_MOTION, crop_allowed

    assert crop_allowed("high", 10.0) is True
    assert crop_allowed("low", 10.0) is False
    assert crop_allowed("high", MAX_CROP_MOTION) is False
    assert crop_allowed("high", MAX_CROP_MOTION + 5.0) is False


def test_crop_allowed_denies_when_motion_score_is_unknown():
    # A clip with no motion score (older Stage 1 output, or a scoring
    # failure) must fail closed: no data, no tight crop.
    from postroll.ai.select_reel_clips import crop_allowed

    assert crop_allowed("high", None) is False


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
    # 30 clips at 2.5s valid_trim each: the pacing floor (15) is met at
    # 37.5s of span, but the duration budget (45s) isn't covered until the
    # 18th clip, so the budget keeps supplying candidates past the floor
    # and the 19th onward (lower-scored) must not be included.
    usable = [
        {"path": f"/clips/c{i}.mov", "score": float(30 - i), "valid_trim": (0.0, 2.5)}
        for i in range(30)
    ]

    candidates = _select_candidates(usable)

    assert len(candidates) == 18
    assert [c["path"] for c in candidates] == [f"/clips/c{i}.mov" for i in range(18)]


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

    # 5s clips: the budget (45s) is covered by 9 clips, but the pacing
    # floor (issue #150: 12-13 cuts need at least that many distinct clips
    # to cut between) keeps supplying candidates up to 15, one frame each here.
    assert captured["count"] == 15
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
