"""Tests for the Friday auto-cut clip reel gate in generate_media.py (Phase 3, #134).

Stage 1 (score_clips) runs for real against ffmpeg-generated synthetic
clips, matching test_clip_scorer.py's fixtures. Stage 2 (select_reel_clips)
and the Jamendo fetch are monkeypatched at the generate_media module
boundary, the same boundary test_select_reel_clips.py already mocks at,
so these tests don't depend on network access or a Claude API key.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


import postroll.ai.generate_media as gm_mod
import postroll.media.generate_title_card as card_mod

# One shared gate (#106): POSTROLL_REQUIRE_FFMPEG=1 turns a silent skip into
# a loud failure, which is what CI needs.
from conftest import HAVE_FFMPEG, needs_ffmpeg  # noqa: F401

# NOT marked slow, as of #1261, and this file is the reason that decision is
# worth reading rather than just seeing.
#
# Every check here runs the whole Friday gate, which renders a real reel and,
# since #824, really composites a title card onto it, so it is genuinely one of
# the more expensive files in the suite. It is the fifth dearest today at 61.9s.
#
# It decided where the old share threshold sat NINE times, on readings of 5.0%,
# 5.8%, 4.5%, 4.99%, 6.18%, 4.37%, 5.97%, 5.17% and 5.96%, the last three within
# a few hours of each other on one machine. Nothing about it changed on any of
# those occasions; the suite around it did, and a share is a ratio.
#
# #1196 replaced the share with a RANK, on the evidence that this file had been
# the fifth dearest in all eight recorded versions of the record. It still is.
# What moved was the file BELOW it: measured 2026-09-04 the sixth dearest is
# 54.5s, a factor of 1.14, and a boundary that close swaps on ordinary noise,
# which is the one thing ranking was adopted to prevent. So the boundary moved
# up to four, where the gap is 1.85x, and this file is now the dearest one the
# fast local loop still pays for.
#
# The marker is not a judgement kept here, which is why removing it is a comment
# and not an argument. It is derived from the recorded distribution in
# tests/file_durations.py, and tests/test_fast_subset_stays_honest.py fails if
# this file and that record disagree in either direction. CI and
# `make test-python` run this file either way throughout (#826, #840, #932).
#
# #976 is where the recurrence itself is dealt with, rather than absorbed again.


def _make_gradient(path, seconds=3.0):
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"testsrc=s=320x240:d={seconds}:r=10", str(path)],
        check=True,
    )


def _make_usable_clips(tmp_path, count=3):
    paths = []
    for i in range(count):
        p = tmp_path / f"clip{i}.mp4"
        _make_gradient(p)
        paths.append(str(p))
    return paths


def _fake_select_reel_clips(scored_clips, **kwargs):
    candidates = [c for c in scored_clips if c.get("usable")]
    return {
        "selections": [
            {
                "clip_path": c["path"],
                "trim_in": c["valid_trim"][0],
                "trim_out": c["valid_trim"][1],
                "transition_after": "cut",
                # apply_selection always returns these (plan #148 Phase 0/2);
                # a fake return that omitted them would mask the
                # generate_media.py translation silently dropping them.
                "crop_x": 0.3,
                "crop_y": -0.15,
                "crop_confidence": "high",
            }
            for c in candidates
        ],
        "rationale": "test rationale",
    }


def _base_manifest(clips, tmp_path, **friday_extra):
    friday = {"clips": clips}
    friday.update(friday_extra)
    return {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"friday": friday},
    }


@needs_ffmpeg
def test_friday_with_usable_clips_produces_reel_and_clip_plan(tmp_path, monkeypatch):
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    manifest = _base_manifest(clips, tmp_path)
    out_dir = tmp_path / "out"
    result = gm_mod.generate_media(manifest, out_dir)

    assert "friday" not in result.get("errors", {})
    friday_result = result["friday"]
    assert friday_result is not None
    assert "reel" in friday_result
    assert friday_result["reel"].endswith(".mp4")
    plan = friday_result["friday_clip_plan"]
    assert len(plan["selections"]) == 3
    assert plan["selections"][0]["transition"] == "cut"
    # Crop fields (plan #148, Phase 2) must survive this translation, not
    # silently drop before ever reaching Swift's FridayClipSelection.
    assert plan["selections"][0]["crop_x"] == 0.3
    assert plan["selections"][0]["crop_y"] == -0.15
    assert plan["selections"][0]["crop_confidence"] == "high"
    # Reel replaces before/after/story for this day, not alongside it.
    assert "before_after" not in friday_result
    assert "story" not in friday_result


# ===================================================================
# Title card overlay (plan #148, Phase 3): applied by default after the
# reel renders, skippable per event via title_card_muted.
# ===================================================================

@needs_ffmpeg
def test_title_card_applied_by_default(tmp_path, monkeypatch):
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    captured = {}

    def fake_apply_title_card(video_path, event_name, output_path, **kwargs):
        captured["event_name"] = event_name
        Path(output_path).write_bytes(Path(video_path).read_bytes())
        return str(output_path)

    monkeypatch.setattr(card_mod, "apply_title_card", fake_apply_title_card)

    manifest = _base_manifest(clips, tmp_path)
    result = gm_mod.generate_media(manifest, tmp_path / "out")

    assert "friday" not in result.get("errors", {})
    assert captured.get("event_name") == "Test Show"


@needs_ffmpeg
def test_title_card_skipped_when_muted(tmp_path, monkeypatch):
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    called = {"count": 0}

    def fake_apply_title_card(video_path, event_name, output_path, **kwargs):
        called["count"] += 1
        return str(output_path)

    monkeypatch.setattr(card_mod, "apply_title_card", fake_apply_title_card)

    manifest = _base_manifest(clips, tmp_path, title_card_muted=True)
    result = gm_mod.generate_media(manifest, tmp_path / "out")

    assert "friday" not in result.get("errors", {})
    assert called["count"] == 0


@needs_ffmpeg
def test_title_card_failure_does_not_fail_the_whole_reel(tmp_path, monkeypatch):
    # The title card is a finishing touch, not the product: if it fails for
    # any reason, the reel Stage 1/2/3 already built must still ship.
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    def failing_apply_title_card(video_path, event_name, output_path, **kwargs):
        raise card_mod.TitleCardError("boom")

    monkeypatch.setattr(card_mod, "apply_title_card", failing_apply_title_card)

    manifest = _base_manifest(clips, tmp_path)
    result = gm_mod.generate_media(manifest, tmp_path / "out")

    assert "friday" not in result.get("errors", {})
    friday_result = result["friday"]
    assert friday_result["reel"].endswith(".mp4")
    assert Path(friday_result["reel"]).exists()


@needs_ffmpeg
def test_friday_with_insufficient_clips_falls_back_to_story(tmp_path, monkeypatch):
    # Only 1 clip: below MIN_USABLE_CLIPS (3), Stage 1 must raise and the
    # gate must fall through to the existing story fallback, unmodified.
    clips = _make_usable_clips(tmp_path, count=1)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    from PIL import Image
    photo = tmp_path / "photo.jpg"
    Image.new("RGB", (400, 600), "green").save(photo)

    manifest = _base_manifest(clips, tmp_path, photos=[str(photo)])
    out_dir = tmp_path / "out"
    result = gm_mod.generate_media(manifest, out_dir)

    friday_result = result["friday"]
    assert "reel" not in friday_result
    assert "story" in friday_result
    assert "friday" in result["errors"], "a clip attempt that fell back must still flag the failure, not go silent"
    # Distinguishable prefix (not just generic error text the Swift side
    # would have to string-match against a message meant for humans): the
    # UI needs to reliably tell "too few usable clips" apart from any other
    # clip-reel failure to show the two specific escape-hatch buttons.
    assert result["errors"]["friday"].startswith("insufficient_clips:")


@needs_ffmpeg
def test_friday_with_other_clip_reel_failure_uses_generic_prefix(tmp_path, monkeypatch):
    # A non-InsufficientClipsError failure (e.g. Stage 2/Claude) must NOT be
    # mistaken for the insufficient-clips case.
    clips = _make_usable_clips(tmp_path)

    def _raising_select(*args, **kwargs):
        raise RuntimeError("Claude API timeout")

    monkeypatch.setattr(gm_mod, "select_reel_clips", _raising_select)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    manifest = _base_manifest(clips, tmp_path)
    out_dir = tmp_path / "out"
    result = gm_mod.generate_media(manifest, out_dir)

    assert result["errors"]["friday"].startswith("clip reel skipped:")
    assert not result["errors"]["friday"].startswith("insufficient_clips:")


@needs_ffmpeg
def test_friday_with_no_clips_behaves_exactly_as_before(tmp_path):
    # No clips key at all: today's before/after path must be completely
    # unaffected by this feature.
    raw = tmp_path / "raw.mp4"
    _make_gradient(raw)  # placeholder file; generate_before_after is a still-image generator so use PNGs instead
    from PIL import Image
    raw_png = tmp_path / "raw.png"
    edit_png = tmp_path / "edit.png"
    Image.new("RGB", (400, 600), "red").save(raw_png)
    Image.new("RGB", (400, 600), "blue").save(edit_png)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"friday": {"raw_photo": str(raw_png), "edited_photo": str(edit_png)}},
    }
    out_dir = tmp_path / "out"
    result = gm_mod.generate_media(manifest, out_dir)

    friday_result = result["friday"]
    assert "before_after" in friday_result
    assert "reel" not in friday_result
    assert "friday" not in result.get("errors", {})


def test_static_only_skips_clip_reel_even_with_clips(tmp_path, monkeypatch):
    # static_only must still short-circuit the reel path exactly like it
    # does for Tuesday/Thursday, without needing real ffmpeg-usable clips.
    called = False

    def _spy_select(*args, **kwargs):
        nonlocal called
        called = True
        return {"selections": [], "rationale": ""}

    monkeypatch.setattr(gm_mod, "select_reel_clips", _spy_select)
    manifest = _base_manifest(["/fake/clip.mov"], tmp_path)
    out_dir = tmp_path / "out"
    gm_mod.generate_media(manifest, out_dir, static_only=True)

    assert not called, "static_only must skip the clip reel attempt entirely"


# ===================================================================
# What happens to the fact that a reel shipped untitled (#824).
#
# Keeping the reel when the title card fails is right: the card is a
# finishing touch and Stage 1/2/3 already did the expensive work. What was
# wrong is that the only record of it was a console line, which is gone with
# the process, so a reel Dan posts with no title looked identical to one he
# chose to post with no title.
# ===================================================================

@needs_ffmpeg
def test_title_card_failure_is_recorded_as_a_warning_on_the_day(tmp_path, monkeypatch):
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    def failing_apply_title_card(video_path, event_name, output_path, **kwargs):
        raise card_mod.TitleCardError("ffmpeg title card overlay failed: boom")

    monkeypatch.setattr(card_mod, "apply_title_card", failing_apply_title_card)

    manifest = _base_manifest(clips, tmp_path)
    result = gm_mod.generate_media(manifest, tmp_path / "out")

    # A warning, not an error: the day rendered and the folder is complete.
    # The two get opposite responses downstream, and calling this a failure
    # would suppress an export over a reel that is sitting right there.
    assert "friday" not in result.get("errors", {})
    warning = result.get("warnings", {}).get("friday", "")
    assert "title card" in warning, (
        "a title card that failed has to reach the app, not just the console: "
        f"friday's warning was {warning!r}"
    )
    # The reason ffmpeg gave, carried through rather than flattened to
    # "something went wrong": distinct causes get distinct messages.
    assert "boom" in warning

    assert Path(result["friday"]["reel"]).exists()


@needs_ffmpeg
def test_a_muted_title_card_is_not_a_warning(tmp_path, monkeypatch):
    # Muting is Dan's own choice, made in the app, which already knows it.
    # Reporting it back as a warning puts a note on every deliberately
    # untitled reel, and a warning that fires on the normal case stops being
    # read (L36).
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    manifest = _base_manifest(clips, tmp_path, title_card_muted=True)
    result = gm_mod.generate_media(manifest, tmp_path / "out")

    assert "friday" not in result.get("errors", {})
    assert "title card" not in result.get("warnings", {}).get("friday", "")
