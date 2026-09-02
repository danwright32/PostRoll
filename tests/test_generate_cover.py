"""Tests for the lightweight cover-only regeneration entrypoint (Phase 3,
#141): far cheaper than a full generate_media() day run, since it never
touches the reel/story.

Two modes:
- override: render directly from a user-chosen source, no Claude call.
- regenerate: pick fresh via Claude. Thursday's candidates are the day's own
  photos; Friday's are frames re-extracted from the day's already-persisted
  clips_plan (never a fresh Stage 1/2 recut, mirroring generate_week.py's
  own _extract_clip_plan_frames rationale: Stage 2's own representative
  frames live in a TemporaryDirectory long gone by the time this runs).
"""

from __future__ import annotations

import shutil
import subprocess

import pytest
from PIL import Image

import postroll.ai.generate_cover as gc_mod

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg/ffprobe not installed")


def _make_gradient(path, seconds=3.0):
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"testsrc=s=320x240:d={seconds}:r=10", str(path)],
        check=True,
    )


def test_override_mode_renders_directly_without_claude_call(monkeypatch, tmp_path):
    source = tmp_path / "chosen.jpg"
    Image.new("RGB", (400, 600), "blue").save(source)
    output = tmp_path / "cover.png"

    def _spy_select_cover_photo(*args, **kwargs):
        raise AssertionError("select_cover_photo must not be called in override mode")

    captured = {}

    def fake_generate_story(*, photo_path, event_name, org, venue, output_path, logo_path=None):
        captured["photo_path"] = photo_path
        Image.new("RGB", (10, 10)).save(output_path)
        return output_path

    monkeypatch.setattr(gc_mod, "select_cover_photo", _spy_select_cover_photo)
    monkeypatch.setattr(gc_mod, "generate_story", fake_generate_story)

    result = gc_mod.generate_cover(
        day_name="friday", day_info={}, event="Test Show", org="Org", venue="Hall",
        output_path=str(output), override_source=str(source),
    )

    assert captured["photo_path"] == str(source)
    assert result == {"cover": str(output)}


def test_thursday_is_refused_even_with_an_override(tmp_path):
    """Thursday's regenerate branch is gone (#961), and the refusal is BY NAME
    and BEFORE the override branch.

    The app's control is gone with it, but this is a CLI entry point and every
    Thursday made before the change still carries a `cover_source` in
    events.json, so the override path is exactly the one a stale caller
    reaches. `override_source` is tested before the day is, so without a named
    refusal Thursday would fall through it and write a story composite into a
    day whose export is not supposed to have one, quietly and successfully
    (L214).

    This replaces the test that asserted Thursday PICKS a cover from the day's
    photos. Its whole content was the behaviour being removed, so it is deleted
    rather than adjusted.
    """
    source = tmp_path / "chosen.jpg"
    Image.new("RGB", (400, 600), "blue").save(source)
    output = tmp_path / "cover.png"

    with pytest.raises(ValueError, match="thursday"):
        gc_mod.generate_cover(
            day_name="thursday", day_info={"photos": [str(source)]},
            event="Test Show", org="Org", venue="Hall", output_path=str(output))

    with pytest.raises(ValueError, match="thursday"):
        gc_mod.generate_cover(
            day_name="thursday", day_info={"photos": [str(source)]},
            event="Test Show", org="Org", venue="Hall", output_path=str(output),
            override_source=str(source))

    assert not output.exists(), "a refused regeneration must leave no cover behind"


def test_friday_regenerate_mode_extracts_frames_from_persisted_clips_plan(monkeypatch, tmp_path):
    clip = tmp_path / "clip.mp4"
    _make_gradient(clip)
    output = tmp_path / "cover.png"
    day_info = {
        "clips_plan": {
            "selections": [
                {"clip_path": str(clip), "trim_in": 0.2, "trim_out": 2.0, "transition": "cut"},
            ],
        }
    }

    def fake_select_cover_photo(candidates, **kwargs):
        assert len(candidates) > 0
        return {"index": 0, "path": candidates[0]["path"], "rationale": "strong wide shot"}

    def fake_generate_story(*, photo_path, event_name, org, venue, output_path, logo_path=None):
        Image.new("RGB", (10, 10)).save(output_path)
        return output_path

    monkeypatch.setattr(gc_mod, "select_cover_photo", fake_select_cover_photo)
    monkeypatch.setattr(gc_mod, "generate_story", fake_generate_story)

    result = gc_mod.generate_cover(
        day_name="friday", day_info=day_info,
        event="Test Show", org="Org", venue="Hall", output_path=str(output),
    )

    assert result["cover"] == str(output)
    assert result["cover_pick"]["rationale"] == "strong wide shot"
    # The winning frame lives in a temp dir that's cleaned up right after
    # selection; it must be persisted permanently (next to cover.png) so a
    # later sticky-gate regen can still find it via source_path.
    from pathlib import Path
    assert Path(result["cover_pick"]["source_path"]).exists()
    assert Path(result["cover_pick"]["source_path"]).parent == tmp_path


def test_friday_regenerate_mode_raises_without_persisted_clips_plan(tmp_path):
    with pytest.raises(ValueError, match="clips_plan"):
        gc_mod.generate_cover(
            day_name="friday", day_info={}, event="Test Show", org="Org", venue="Hall",
            output_path=str(tmp_path / "cover.png"),
        )


def test_unsupported_day_raises(tmp_path):
    with pytest.raises(ValueError, match="wednesday"):
        gc_mod.generate_cover(
            day_name="wednesday", day_info={}, event="Test Show", org="Org", venue="Hall",
            output_path=str(tmp_path / "cover.png"),
        )
