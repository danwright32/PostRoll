"""Tests for the Instagram grid cover image wiring in generate_media.py
(Phase 1, #139): Thursday's candidate list (day photos, capped via
select_reel_photos's representative sampling above DEFAULT_MAX_REEL_PHOTOS),
Friday's candidate list (frames extracted from the clip reel's already-cut
plan), and the sticky gate that skips Claude entirely once a cover_source is
already persisted for the day.

select_cover_photo is monkeypatched at the generate_media module boundary,
the same boundary test_generate_media_friday_clips.py already mocks Stage 2
at. select_reel_photos is monkeypatched at select_cover_photo (where the
candidate-building helpers actually live, shared with generate_cover.py's
lightweight regen path) so these don't depend on network access or a
Claude API key.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest
from PIL import Image

import postroll.ai.generate_media as gm_mod
import postroll.ai.select_cover_photo as scp_mod
from postroll.ai.select_reel_photos import DEFAULT_MAX_REEL_PHOTOS

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg/ffprobe not installed")


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
                # a fake return that omitted them doesn't match the real
                # contract generate_media.py's translation depends on.
                "crop_x": 0.0,
                "crop_y": 0.0,
                "crop_confidence": "low",
            }
            for c in candidates
        ],
        "rationale": "test rationale",
    }


def _make_photos(tmp_path, count):
    paths = []
    for i in range(count):
        p = tmp_path / f"p{i:03d}.jpg"
        Image.new("RGB", (400, 600), (i % 255, 0, 0)).save(p)
        paths.append(str(p))
    return paths


# ===================================================================
# Pure candidate-building functions (no Claude, no ffmpeg for Thursday)
# ===================================================================

def test_thursday_cover_candidates_use_all_photos_when_under_cap(tmp_path):
    photos = _make_photos(tmp_path, 5)

    candidates = gm_mod._cover_candidates_from_photos(photos)

    assert [c["path"] for c in candidates] == photos


def test_thursday_cover_candidates_capped_via_representative_sampling_when_over_cap(monkeypatch, tmp_path):
    photos = _make_photos(tmp_path, DEFAULT_MAX_REEL_PHOTOS + 10)
    captured = {}

    def fake_select_reel_photos(paths, count):
        captured["paths"] = paths
        captured["count"] = count
        return paths[:count]

    monkeypatch.setattr(scp_mod, "select_reel_photos", fake_select_reel_photos)

    candidates = gm_mod._cover_candidates_from_photos(photos)

    assert captured["count"] == DEFAULT_MAX_REEL_PHOTOS
    assert len(candidates) == DEFAULT_MAX_REEL_PHOTOS


@needs_ffmpeg
def test_friday_cover_candidates_extract_frames_per_selected_clip(tmp_path):
    clips = _make_usable_clips(tmp_path, count=2)
    selections = [
        {"clip_path": clips[0], "trim_in": 0.2, "trim_out": 2.0, "transition_after": "cut"},
        {"clip_path": clips[1], "trim_in": 0.5, "trim_out": 2.5, "transition_after": "cut"},
    ]

    candidates = gm_mod._cover_candidates_from_friday_plan(selections, tmp_path)

    assert len(candidates) == len(selections) * gm_mod.COVER_FRAMES_PER_CLIP
    for c in candidates:
        assert Path(c["path"]).exists()


# ===================================================================
# Integration: generate_media() wiring (select_cover_photo mocked)
# ===================================================================

def test_thursday_generates_cover_from_photos(monkeypatch, tmp_path):
    photos = _make_photos(tmp_path, 3)

    def fake_select_cover_photo(candidates, **kwargs):
        return {"index": 1, "path": candidates[1]["path"], "rationale": "test pick"}

    monkeypatch.setattr(gm_mod, "select_cover_photo", fake_select_cover_photo)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"thursday": {"photos": photos}},
    }
    result = gm_mod.generate_media(manifest, tmp_path / "out", static_only=True)

    thursday_result = result["thursday"]
    assert "cover" in thursday_result
    assert thursday_result["cover_pick"] == {"source_path": photos[1], "rationale": "test pick"}


def test_thursday_cover_sticky_gate_skips_selection_when_cover_source_present(monkeypatch, tmp_path):
    photos = _make_photos(tmp_path, 3)

    def _spy_select_cover_photo(*args, **kwargs):
        raise AssertionError("select_cover_photo must not be called when cover_source is persisted")

    def _spy_select_reel_photos(*args, **kwargs):
        raise AssertionError("select_reel_photos must not be called when cover_source is persisted")

    monkeypatch.setattr(gm_mod, "select_cover_photo", _spy_select_cover_photo)
    monkeypatch.setattr(scp_mod, "select_reel_photos", _spy_select_reel_photos)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"thursday": {"photos": photos, "cover_source": photos[0]}},
    }
    result = gm_mod.generate_media(manifest, tmp_path / "out", static_only=True)

    thursday_result = result["thursday"]
    assert "cover" in thursday_result
    assert "cover_pick" not in thursday_result


def test_cover_render_failure_is_reported_not_silent(tmp_path):
    # Phase 5 (#143) failure-path sweep: a cover_source pointing at a photo
    # that no longer exists on disk must surface as a reported error, not
    # succeed silently or crash the whole day's generation.
    photos = _make_photos(tmp_path, 1)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"thursday": {"photos": photos, "cover_source": str(tmp_path / "does_not_exist.jpg")}},
    }
    result = gm_mod.generate_media(manifest, tmp_path / "out", static_only=True)

    thursday_result = result["thursday"]
    assert "cover" not in thursday_result
    assert result["errors"]["thursday"].startswith("cover failed:")


@needs_ffmpeg
def test_friday_cover_generated_from_clip_reel_frames(monkeypatch, tmp_path):
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    def fake_select_cover_photo(candidates, **kwargs):
        return {"index": 0, "path": candidates[0]["path"], "rationale": "test pick"}

    monkeypatch.setattr(gm_mod, "select_cover_photo", fake_select_cover_photo)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"friday": {"clips": clips}},
    }
    result = gm_mod.generate_media(manifest, tmp_path / "out")

    friday_result = result["friday"]
    assert "cover" in friday_result
    assert "cover_pick" in friday_result
    # The winning frame must be persisted permanently (not left inside a
    # temp dir that's already been cleaned up by the time this returns),
    # so a later sticky-gate regen can still find it.
    assert Path(friday_result["cover_pick"]["source_path"]).exists()


@needs_ffmpeg
def test_friday_cover_not_generated_when_clip_reel_not_rendered(tmp_path):
    # Only 1 clip: below MIN_USABLE_CLIPS, falls back to before/after, so no
    # clip plan exists to extract cover frames from, and thus no cover either.
    clips = _make_usable_clips(tmp_path, count=1)
    raw = tmp_path / "raw.jpg"
    edit = tmp_path / "edit.jpg"
    Image.new("RGB", (400, 600), "green").save(raw)
    Image.new("RGB", (400, 600), "blue").save(edit)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"friday": {"clips": clips, "raw_photo": str(raw), "edited_photo": str(edit)}},
    }
    result = gm_mod.generate_media(manifest, tmp_path / "out")

    friday_result = result["friday"]
    assert "cover" not in friday_result


@needs_ffmpeg
def test_friday_cover_sticky_gate_skips_selection_when_cover_source_present(monkeypatch, tmp_path):
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    persisted_source = tmp_path / "persisted_cover.jpg"
    Image.new("RGB", (400, 600), "purple").save(persisted_source)

    def _spy_select_cover_photo(*args, **kwargs):
        raise AssertionError("select_cover_photo must not be called when cover_source is persisted")

    monkeypatch.setattr(gm_mod, "select_cover_photo", _spy_select_cover_photo)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"friday": {"clips": clips, "cover_source": str(persisted_source)}},
    }
    result = gm_mod.generate_media(manifest, tmp_path / "out")

    friday_result = result["friday"]
    assert "cover" in friday_result
    assert "cover_pick" not in friday_result
