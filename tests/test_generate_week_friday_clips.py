"""Tests for unblocking Friday captions in generate_week.py (Phase 3, #134).

Friday's caption used to be unconditionally skipped. It now generates when
the manifest carries a persisted Stage 2 clip plan (clips_plan), re-extracting
representative frames itself rather than depending on Stage 2's already-deleted
temp JPEGs or timing against the separate media-generation subprocess.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

import postroll.ai.generate_week as gw_mod
from postroll.ai.generate_week import _extract_clip_plan_frames

# One shared gate (#106): POSTROLL_REQUIRE_FFMPEG=1 turns a silent skip into
# a loud failure, which is what CI needs.
from conftest import HAVE_FFMPEG, needs_ffmpeg  # noqa: F401


def _make_clip(path, seconds=4.0):
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"testsrc=s=320x240:d={seconds}:r=10", str(path)],
        check=True,
    )


@needs_ffmpeg
def test_extract_clip_plan_frames_returns_one_frame_per_selection(tmp_path):
    clip_a = tmp_path / "a.mp4"
    clip_b = tmp_path / "b.mp4"
    _make_clip(clip_a)
    _make_clip(clip_b)
    selections = [
        {"clip_path": str(clip_a), "trim_in": 0.5, "trim_out": 3.5},
        {"clip_path": str(clip_b), "trim_in": 1.0, "trim_out": 3.0},
    ]

    frames = _extract_clip_plan_frames(selections, tmp_dir=tmp_path / "frames")

    assert len(frames) == 2
    for f in frames:
        assert Path(f).exists()


@needs_ffmpeg
def test_extract_clip_plan_frames_skips_missing_clip_file(tmp_path):
    clip_a = tmp_path / "a.mp4"
    _make_clip(clip_a)
    selections = [
        {"clip_path": str(clip_a), "trim_in": 0.5, "trim_out": 3.5},
        {"clip_path": str(tmp_path / "gone.mp4"), "trim_in": 0.0, "trim_out": 2.0},
    ]

    frames = _extract_clip_plan_frames(selections, tmp_dir=tmp_path / "frames")

    assert len(frames) == 1


def test_extract_clip_plan_frames_raises_when_no_frames_extracted(tmp_path):
    selections = [
        {"clip_path": str(tmp_path / "gone1.mp4"), "trim_in": 0.0, "trim_out": 2.0},
        {"clip_path": str(tmp_path / "gone2.mp4"), "trim_in": 0.0, "trim_out": 2.0},
    ]

    with pytest.raises(RuntimeError):
        _extract_clip_plan_frames(selections, tmp_dir=tmp_path / "frames")


def _fake_generate_caption(**kwargs):
    return {
        "caption": "fake caption", "hashtags": [], "alt_texts": ["fake alt"],
        "scene_labels": [], "_kwargs": kwargs,
    }


@needs_ffmpeg
def test_friday_with_clip_plan_generates_caption_as_clip_reel(tmp_path, monkeypatch):
    clip_a = tmp_path / "a.mp4"
    clip_b = tmp_path / "b.mp4"
    _make_clip(clip_a)
    _make_clip(clip_b)

    monkeypatch.setattr(gw_mod, "generate_caption", _fake_generate_caption)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "program": {},
        "days": {
            "friday": {
                "clips_plan": {
                    "selections": [
                        {"clip_path": str(clip_a), "trim_in": 0.5, "trim_out": 3.5, "transition": "cut"},
                        {"clip_path": str(clip_b), "trim_in": 0.5, "trim_out": 3.5, "transition": "crossfade"},
                    ],
                    "rationale": "opens strong",
                },
                "tag_handles": ["@venue"],
            },
        },
    }
    out = tmp_path / "out.json"
    gw_mod.generate_week(manifest, out)

    result = json.loads(out.read_text())
    assert result["friday"] is not None
    assert result["friday"]["_kwargs"]["post_type"] == "clip_reel"
    assert len(result["friday"]["_kwargs"]["photo_paths"]) == 2
    assert result["friday"]["_kwargs"]["tag_handles"] == ["@venue"]
    assert "friday" not in result.get("errors", {})


@needs_ffmpeg
def test_the_friday_caption_frames_do_not_outlive_the_run(tmp_path, monkeypatch):
    """The extracted frames are scratch, and the run has to take them with it.

    They used to go into a mkdtemp that nothing ever removed, so the temp volume
    grew with how often the workflow ran rather than with how much work was done,
    and stayed until the OS purge (#486, L114). The private temp directory here
    is what makes the leak visible: against the real one, a leaked folder is a
    needle in a haystack nobody looks at.
    """
    scratch = tmp_path / "tempvol"
    scratch.mkdir()
    monkeypatch.setattr(gw_mod.tempfile, "tempdir", str(scratch))

    clip = tmp_path / "a.mp4"
    _make_clip(clip)
    monkeypatch.setattr(gw_mod, "generate_caption", _fake_generate_caption)

    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "program": {},
        "days": {
            "friday": {
                "clips_plan": {
                    "selections": [
                        {"clip_path": str(clip), "trim_in": 0.5, "trim_out": 3.5},
                    ],
                },
            },
        },
    }
    out = tmp_path / "out.json"
    gw_mod.generate_week(manifest, out)

    # The frames were really extracted and really used, so the emptiness below
    # is cleanup rather than the Friday branch never having run (L98).
    result = json.loads(out.read_text())
    assert result["friday"] is not None
    assert len(result["friday"]["_kwargs"]["photo_paths"]) == 1

    leftovers = sorted(p.name for p in scratch.iterdir())
    assert leftovers == [], f"the run left {leftovers} behind in the temp volume"


@needs_ffmpeg
def test_extract_clip_plan_frames_will_not_invent_its_own_directory(tmp_path):
    """The caller owns the scratch directory, because the caller is what knows
    when the frames stop being needed. A default that minted one here is how the
    leak above existed at all (L8)."""
    with pytest.raises(TypeError):
        _extract_clip_plan_frames([{"clip_path": "/nope.mp4"}])


def test_friday_with_no_clip_plan_skips_caption_as_before(tmp_path):
    manifest = {
        "event": "Test Show", "org": "Org", "venue": "Hall", "date": "2026-01-01",
        "program": {},
        "days": {"friday": {}},
    }
    out = tmp_path / "out.json"
    gw_mod.generate_week(manifest, out)

    result = json.loads(out.read_text())
    assert result["friday"] is None
    assert "friday" not in result.get("errors", {})
