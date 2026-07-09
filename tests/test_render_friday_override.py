"""Tests for re-rendering the Friday clip reel from a user's manual override
(reorder/include-exclude/swap), skipping Stage 1/2 entirely (Phase 4, #135).
"""

from __future__ import annotations

import shutil
import subprocess
from unittest.mock import patch

import pytest

from postroll.ai.render_friday_override import render_friday_override

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg/ffprobe not installed")


def _make_clip(path, seconds=4.0):
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"testsrc=s=320x240:d={seconds}:r=10", str(path)],
        check=True,
    )


def test_empty_selections_raises(tmp_path):
    manifest = {"selections": []}
    with pytest.raises(ValueError):
        render_friday_override(manifest, tmp_path / "out.mp4")


@needs_ffmpeg
def test_renders_reel_from_override_selections_without_claude(tmp_path):
    clip_a = tmp_path / "a.mp4"
    clip_b = tmp_path / "b.mp4"
    _make_clip(clip_a)
    _make_clip(clip_b)

    manifest = {
        "selections": [
            {"clip_path": str(clip_a), "trim_in": 0.0, "trim_out": 3.0, "transition": "cut"},
            {"clip_path": str(clip_b), "trim_in": 0.0, "trim_out": 3.0, "transition": "crossfade"},
        ],
        "shoot_type": "performance",
        "pieces": [],
    }
    out = tmp_path / "reel.mp4"

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None) as mock_resolve:
        render_friday_override(manifest, out)

    assert out.exists()
    mock_resolve.assert_called_once()


# ===================================================================
# Crop fields threading (issue #151): a manual override must not silently
# drop the AI's crop choice just because it only carries clip path, trim,
# and transition through the rest of this manifest.
# ===================================================================

def test_crop_fields_from_manifest_pass_through_to_render(tmp_path):
    manifest = {
        "selections": [
            {"clip_path": "/clips/a.mov", "trim_in": 0.0, "trim_out": 3.0,
             "transition": "cut", "crop_x": 0.4, "crop_y": -0.2},
        ],
    }

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel") as mock_render:
        render_friday_override(manifest, tmp_path / "out.mp4")

    rendered_selections = mock_render.call_args[0][0]
    assert rendered_selections[0]["crop_x"] == 0.4
    assert rendered_selections[0]["crop_y"] == -0.2


def test_missing_crop_fields_default_to_centered(tmp_path):
    manifest = {
        "selections": [
            {"clip_path": "/clips/a.mov", "trim_in": 0.0, "trim_out": 3.0, "transition": "cut"},
        ],
    }

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel") as mock_render:
        render_friday_override(manifest, tmp_path / "out.mp4")

    rendered_selections = mock_render.call_args[0][0]
    assert rendered_selections[0]["crop_x"] == 0.0
    assert rendered_selections[0]["crop_y"] == 0.0


@needs_ffmpeg
def test_user_provided_audio_file_passed_through(tmp_path):
    clip_a = tmp_path / "a.mp4"
    _make_clip(clip_a)
    audio = tmp_path / "music.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", "sine=frequency=220:duration=10", str(audio)],
        check=True,
    )

    manifest = {
        "selections": [{"clip_path": str(clip_a), "trim_in": 0.0, "trim_out": 3.0, "transition": "cut"}],
        "audio": str(audio),
    }
    out = tmp_path / "reel.mp4"

    render_friday_override(manifest, out)

    assert out.exists()
