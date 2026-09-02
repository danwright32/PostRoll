"""Tests for the Instagram grid cover image wiring in generate_media.py
(Phase 1, #139): Friday's candidate list (frames extracted from the clip
reel's already-cut plan), the sticky gate that skips Claude entirely once a
cover_source is already persisted for the day, and the error branch a cover
that cannot be rendered has to take.

Thursday's half is gone (#961). What remains of it here are the checks that it
produces NO cover, including through the sticky gate, because every Thursday
made before that still carries a cover_source in events.json.

select_cover_photo is monkeypatched at the generate_media module boundary,
the same boundary test_generate_media_friday_clips.py already mocks Stage 2
at, so these don't depend on network access or a Claude API key.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest
from PIL import Image

import postroll.ai.generate_media as gm_mod
import postroll.ai.select_cover_photo as scp_mod

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

def test_cover_render_failure_is_reported_not_silent(tmp_path):
    # Phase 5 (#143) failure-path sweep: a cover_source pointing at a photo
    # that no longer exists on disk must surface as a reported error, not
    # succeed silently.
    #
    # Driven through `_render_cover` directly, and named for Friday. It used to
    # go through a whole Thursday generation, and Thursday has no cover since
    # #961; the branch it protects is day agnostic and Friday still reaches it,
    # so the coverage moves rather than going with the day (L129).
    day_dir = tmp_path / "friday"
    day_dir.mkdir()
    day_result, errors = {}, {}

    gm_mod._render_cover(
        day_name="friday",
        day_dir=day_dir,
        day_info={"cover_source": str(tmp_path / "does_not_exist.jpg")},
        build_candidates=lambda: (_ for _ in ()).throw(
            AssertionError("candidates must not be built when cover_source is set")),
        event="Test Show", org="Org", venue="Hall",
        day_result=day_result, errors=errors,
    )

    assert "cover" not in day_result, "a failed cover must not report a path"
    assert errors["friday"].startswith("cover failed:")
    assert not (day_dir / "cover.png").exists()


@needs_ffmpeg
def test_fridays_cover_pick_is_told_what_the_week_already_used(monkeypatch, tmp_path):
    """The wiring half of #144: a picker nothing passes the used set to is the
    same as no picker (L3).

    It used to run against Thursday, whose candidates were the day's own photos
    and which could be reached with two jpegs. Thursday has no cover since #961,
    so it runs against the only day that still has one, which means cutting a
    clip reel to get there.
    """
    clips = _make_usable_clips(tmp_path)
    monkeypatch.setattr(gm_mod, "select_reel_clips", _fake_select_reel_clips)
    monkeypatch.setattr(gm_mod, "resolve_reel_audio", lambda audio_file, **kwargs: None)

    shared = tmp_path / "shared.jpg"
    Image.new("RGB", (400, 600), (10, 20, 30)).save(shared)

    excluded_seen: list[list[str]] = []

    def spy_pick(candidates, **kwargs):
        excluded_seen.append(list(kwargs.get("exclude_paths") or []))
        return {"index": 0, "path": candidates[0]["path"], "rationale": "r"}

    monkeypatch.setattr(gm_mod, "select_cover_photo", spy_pick)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {
            "tuesday": {"raw_photo": str(shared), "edited_photo": str(shared)},
            "friday": {"clips": clips},
        },
    }
    gm_mod.generate_media(manifest, tmp_path / "out")

    assert excluded_seen, "no cover pick was attempted, so this proves nothing"
    assert any(str(shared) in paths for paths in excluded_seen), (
        f"the cover pick was told {excluded_seen}, which does not include the "
        f"photo Tuesday already used")


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


# ===================================================================
# Thursday has no cover (#961)
# ===================================================================
#
# Dan asked for the whole slot to go on 2026-08-29, and chose to drop the
# ASSET as well as the panel: no cover.png in Thursday's export folder, and
# Instagram picks its own grid thumbnail from a frame of the reel. Thursday's
# cover was a full story composite, so it read as a story sitting under the
# reel, which is not a post he makes that day.
#
# These replace the assertions that used to defend the behaviour rather than
# being adjusted to fit it: their whole content was the thing being removed.

def test_thursday_produces_no_cover(monkeypatch, tmp_path):
    def _never(*args, **kwargs):
        raise AssertionError(
            "a cover was picked for Thursday, which no longer has one, and each "
            "call is a Claude request per Thursday")

    monkeypatch.setattr(gm_mod, "select_cover_photo", _never)

    photos = _make_photos(tmp_path, 3)
    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"thursday": {"photos": photos}},
    }
    out = tmp_path / "out"
    result = gm_mod.generate_media(manifest, out, static_only=True)

    thursday_result = result["thursday"] or {}
    assert "cover" not in thursday_result
    assert "cover_pick" not in thursday_result
    assert not result.get("errors", {}).get("thursday"), (
        "dropping the cover must not leave an error behind: nothing failed, "
        "there is simply nothing to render")

    # The asset, not just the key. `_render_cover` writes the file and then
    # records it, so a check on the dict alone would pass a run that still put
    # a cover.png in the folder Dan uploads from (L3).
    strays = sorted(p.name for p in out.rglob("cover*"))
    assert strays == [], f"Thursday's export still carries {strays}"


def test_a_persisted_cover_source_does_not_bring_thursdays_cover_back(
        monkeypatch, tmp_path):
    """The sticky gate used to render from `cover_source` without asking Claude.

    Every Thursday generated before this still carries one in events.json, so
    the path that reads it is exactly the one that would quietly keep making
    covers for days that are not supposed to have any (L133).
    """
    def _never(*args, **kwargs):
        raise AssertionError("select_cover_photo ran for Thursday")

    monkeypatch.setattr(gm_mod, "select_cover_photo", _never)

    photos = _make_photos(tmp_path, 3)
    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "days": {"thursday": {"photos": photos, "cover_source": photos[0]}},
    }
    out = tmp_path / "out"
    result = gm_mod.generate_media(manifest, out, static_only=True)

    assert "cover" not in (result["thursday"] or {})
    assert sorted(p.name for p in out.rglob("cover*")) == []
