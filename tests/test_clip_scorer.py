"""Tests for the Friday clip reel's deterministic clip scorer (Stage 1).

No sharpness/motion/blur code existed anywhere in this repo before this.
Genuinely new territory, not a wire-up of an existing pattern. Fixtures are
real ffmpeg-generated synthetic clips (solid color, random noise, a moving
gradient), not mocks, so the scorer is proven against real frame data.

The noise fixture specifically pins the risk the plan-council red team
flagged: per-frame edge-detection alone reads noise as "sharp" (it has tons
of high-frequency detail), so a naive sharpness-only scorer would rank pure
noise as great footage. The motion-coherence check must catch this: noise
is uncorrelated frame to frame, unlike real (even shaky) footage.
"""

from __future__ import annotations

import shutil
import subprocess

import pytest

from postroll.media.clip_scorer import (
    MIN_USABLE_CLIPS,
    InsufficientClipsError,
    _longest_valid_run,
    clip_duration,
    score_clip,
    score_clips,
)

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg/ffprobe not installed")


def _make_solid(path, seconds=3.0):
    """A single flat gray frame held for the whole clip: no edges, no motion.
    Stands in for a badly out-of-focus / blank shot."""
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"color=c=gray:s=320x240:d={seconds}:r=10", str(path)],
        check=True,
    )


def _make_noise(path, seconds=3.0):
    """Fully random luma per pixel per frame: high per-frame edge energy but
    zero frame-to-frame coherence, the "reads as sharp" trap."""
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"nullsrc=s=320x240:d={seconds}:r=10,geq=lum=random(1)*255:cb=128:cr=128",
         str(path)],
        check=True,
    )


def _make_gradient(path, seconds=3.0):
    """ffmpeg's testsrc: real detail (moving bars/gradient) with smooth,
    continuous motion. A stand-in for genuine, usable footage."""
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"testsrc=s=320x240:d={seconds}:r=10", str(path)],
        check=True,
    )


@needs_ffmpeg
def test_clip_duration_matches_actual_length(tmp_path):
    clip = tmp_path / "gradient.mp4"
    _make_gradient(clip, seconds=3.0)
    assert abs(clip_duration(clip) - 3.0) < 0.2


@needs_ffmpeg
def test_solid_color_clip_is_not_usable(tmp_path):
    clip = tmp_path / "solid.mp4"
    _make_solid(clip)

    result = score_clip(clip)

    assert result["usable"] is False
    assert result["valid_trim"] is None


@needs_ffmpeg
def test_noise_clip_is_not_usable_despite_high_raw_sharpness(tmp_path):
    clip = tmp_path / "noise.mp4"
    _make_noise(clip)

    result = score_clip(clip)

    # Noise DOES read as sharp per-frame (lots of edge energy). The whole
    # point of this test is that "usable" must still come back False because
    # consecutive frames are incoherent, not because sharpness was low.
    assert result["usable"] is False
    assert result["valid_trim"] is None


def test_moderate_real_world_motion_between_frames_is_still_coherent():
    # Real bug found 2026-07-08 testing 17 real 4K clips from an actual
    # event: after the sharpness/resolution fix, every frame cleared
    # MIN_SHARPNESS, but only 3 of 17 clips passed overall, because
    # MAX_COHERENT_MOTION (30.0) was calibrated only against a synthetic
    # smooth-pan fixture that scores ~3-7. Real camera footage, even
    # genuinely usable footage with no actual blur, naturally shows
    # inter-frame motion in the 40-65 range from ordinary handheld
    # micro-shake, autofocus, and busy real scenes, nowhere near the ~95 a
    # pure noise clip lands at. The threshold must accept that range.
    sharpness = [50.0] * 8
    motion = [45.0] * 7

    run = _longest_valid_run(sharpness, motion)

    assert run == (0, 7)


@needs_ffmpeg
def test_gradient_clip_is_usable_with_a_valid_trim_spanning_the_clip(tmp_path):
    clip = tmp_path / "gradient.mp4"
    _make_gradient(clip, seconds=3.0)

    result = score_clip(clip)

    assert result["usable"] is True
    assert result["score"] > 0
    start, end = result["valid_trim"]
    assert start < 0.5
    assert end > 2.5, "the whole clip is good footage, the trim window should span nearly all of it"


@needs_ffmpeg
def test_high_resolution_sharp_clip_is_still_usable(tmp_path):
    # Real bug found 2026-07-08 against 17 real 4K clips from an actual
    # event: every one scored below MIN_SHARPNESS despite being genuinely
    # in-focus. Root cause confirmed with this exact fixture: ffmpeg's own
    # "good footage" test pattern, rendered at 4K instead of the original
    # 320x240 SAMPLE_COUNT fixtures, ALSO fails. Edge-detection stddev
    # scales with frame dimensions (a hard edge spans more pixels at higher
    # resolution, so the per-pixel gradient reads lower), not perceptual
    # sharpness, so scoring must normalize to a consistent size first.
    clip = tmp_path / "gradient_4k.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", "testsrc=s=3840x2160:d=3:r=10", str(clip)],
        check=True,
    )

    result = score_clip(clip)

    assert result["usable"] is True


@needs_ffmpeg
def test_score_clip_result_shape(tmp_path):
    clip = tmp_path / "gradient.mp4"
    _make_gradient(clip)

    result = score_clip(clip)

    assert result["path"] == str(clip)
    assert isinstance(result["duration"], float)
    assert isinstance(result["usable"], bool)
    assert isinstance(result["score"], float)


@needs_ffmpeg
def test_score_clips_raises_when_fewer_than_minimum_usable(tmp_path):
    good = tmp_path / "good.mp4"
    _make_gradient(good)
    bad1 = tmp_path / "bad1.mp4"
    _make_solid(bad1)
    bad2 = tmp_path / "bad2.mp4"
    _make_noise(bad2)

    with pytest.raises(InsufficientClipsError):
        score_clips([good, bad1, bad2])


@needs_ffmpeg
def test_score_clips_returns_all_scored_when_minimum_met(tmp_path):
    paths = []
    for i in range(MIN_USABLE_CLIPS):
        p = tmp_path / f"good{i}.mp4"
        _make_gradient(p)
        paths.append(p)

    results = score_clips(paths)

    assert len(results) == MIN_USABLE_CLIPS
    assert all(r["usable"] for r in results)
