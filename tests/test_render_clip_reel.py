"""Tests for rendering Stage 2's clip selection plan into the final reel MP4.

Pure validation/offset-planning tests run anywhere; the end-to-end renders
run ffmpeg and are skipped when ffmpeg/ffprobe aren't on PATH.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

from postroll.media.render_clip_reel import (
    CANVAS_H,
    CANVAS_W,
    DEFAULT_DUCK_GAIN_DB,
    TRANSITION_DURATION,
    RenderClipReelError,
    _scale_pad_filter,
    _xfade_offsets,
    render_clip_reel,
)

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg/ffprobe not installed")


# ===================================================================
# Pure validation / offset planning
# ===================================================================

def test_empty_selections_raises():
    with pytest.raises(RenderClipReelError):
        render_clip_reel([], "/tmp/does-not-matter.mp4")


def test_inverted_trim_window_raises(tmp_path):
    selections = [
        {"clip_path": str(tmp_path / "a.mp4"), "trim_in": 5.0, "trim_out": 2.0, "transition_after": "cut"},
    ]
    with pytest.raises(RenderClipReelError):
        render_clip_reel(selections, tmp_path / "out.mp4")


def test_xfade_offsets_accounts_for_overlap():
    # Two 5s segments joined by a 0.4s crossfade: the second starts playing
    # at 5 - 0.4 = 4.6s into the timeline, not 5.0s (that would be a gap).
    offsets = _xfade_offsets(durations=[5.0, 5.0], transition_durations=[0.4])
    assert offsets == [4.6]


def test_xfade_offsets_chains_multiple_joins():
    offsets = _xfade_offsets(durations=[4.0, 3.0, 6.0], transition_durations=[0.4, 0.4])
    # First join offset: 4.0 - 0.4 = 3.6
    # Second join offset (cumulative): 3.6 + 3.0 - 0.4 = 6.2
    assert offsets == pytest.approx([3.6, 6.2])


# ===================================================================
# Per-clip crop offset (issue #151): the filter must reproduce today's
# exact centered crop when no offset is given, and shift the crop window
# when one is.
# ===================================================================

def test_scale_pad_filter_with_no_offset_matches_todays_centered_crop():
    # Byte-identical to the pre-Phase-2 filter string: existing reels must
    # render exactly as before when crop_x/crop_y are 0 (the default).
    assert _scale_pad_filter(0.0, 0.0) == (
        f"scale={CANVAS_W}:{CANVAS_H}:force_original_aspect_ratio=increase,"
        f"crop={CANVAS_W}:{CANVAS_H},setsar=1"
    )


def test_scale_pad_filter_defaults_to_centered_when_called_with_no_args():
    assert _scale_pad_filter() == _scale_pad_filter(0.0, 0.0)


def test_scale_pad_filter_with_offset_shifts_the_crop_position():
    filter_str = _scale_pad_filter(0.5, -0.5)
    # A non-zero offset must produce an explicit x/y crop position, not
    # the bare "crop=W:H" (which always centers).
    assert f"crop={CANVAS_W}:{CANVAS_H}:" in filter_str
    assert filter_str != _scale_pad_filter(0.0, 0.0)


# ===================================================================
# End-to-end renders (ffmpeg)
# ===================================================================

def _make_clip(path: Path, *, seconds: float, color: str, freq: int = 440) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error",
         "-f", "lavfi", "-i", f"color=c={color}:s=320x180:d={seconds}",
         "-f", "lavfi", "-i", f"sine=frequency={freq}:duration={seconds}",
         "-shortest", "-pix_fmt", "yuv420p", str(path)],
        check=True,
    )


def _probe_duration(path: Path) -> float:
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True,
    )
    return float(proc.stdout.strip())


def _mean_volume_db(path: Path, start: float, end: float) -> float:
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-ss", str(start), "-to", str(end),
         "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    match = re.search(r"mean_volume:\s*(-?\d+(?:\.\d+)?) dB", proc.stderr)
    assert match, f"no mean_volume in ffmpeg output: {proc.stderr[-300:]}"
    return float(match.group(1))


@needs_ffmpeg
def test_render_concatenates_selections_to_expected_duration(tmp_path):
    clip_a = tmp_path / "a.mp4"
    clip_b = tmp_path / "b.mp4"
    _make_clip(clip_a, seconds=6.0, color="red", freq=300)
    _make_clip(clip_b, seconds=6.0, color="blue", freq=800)
    music = tmp_path / "music.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", "sine=frequency=220:duration=20", str(music)],
        check=True,
    )

    selections = [
        {"clip_path": str(clip_a), "trim_in": 0.0, "trim_out": 4.0, "transition_after": "cut"},
        {"clip_path": str(clip_b), "trim_in": 0.0, "trim_out": 4.0, "transition_after": "cut"},
    ]
    out = tmp_path / "reel.mp4"

    render_clip_reel(selections, out, audio_path=music)

    assert out.exists()
    # Two 4s segments with a near-zero "cut" transition: total should land
    # close to 8s, not silently trimmed short or padded long.
    assert abs(_probe_duration(out) - 8.0) < 0.5


@needs_ffmpeg
def test_landscape_source_fills_the_portrait_canvas_not_padded(tmp_path):
    # Dan's feedback (2026-07-08): a landscape clip must fill the 1080x1920
    # portrait canvas (cropping the sides), not letterbox with black bars.
    # A solid-red 320x180 (16:9) source scaled to FIT inside the canvas would
    # leave black padding on the sides; scaled to FILL (cropping the excess
    # top/bottom) leaves no black anywhere in the frame. Sampling a corner
    # pixel distinguishes the two: black corner means padding survived.
    clip = tmp_path / "landscape.mp4"
    _make_clip(clip, seconds=2.0, color="red")
    selections = [
        {"clip_path": str(clip), "trim_in": 0.0, "trim_out": 1.5, "transition_after": "cut"},
    ]
    out = tmp_path / "reel.mp4"

    render_clip_reel(selections, out)

    frame = tmp_path / "frame.png"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-ss", "0.5", "-i", str(out),
         "-frames:v", "1", str(frame)],
        check=True,
    )
    from PIL import Image
    img = Image.open(frame).convert("RGB")
    corner = img.getpixel((0, 0))
    assert corner != (0, 0, 0), (
        f"top-left corner is black {corner}: the source was padded/letterboxed "
        "instead of scaled to fill and crop"
    )


@needs_ffmpeg
def test_muted_clip_audio_leaves_only_music_bed(tmp_path):
    clip = tmp_path / "loud.mp4"
    _make_clip(clip, seconds=5.0, color="green", freq=500)
    music = tmp_path / "music.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", "sine=frequency=220:duration=20", str(music)],
        check=True,
    )
    selections = [
        {"clip_path": str(clip), "trim_in": 0.0, "trim_out": 5.0, "transition_after": "cut"},
    ]

    muted_out = tmp_path / "muted.mp4"
    render_clip_reel(selections, muted_out, audio_path=music, mute_clip_audio=True)

    unmuted_out = tmp_path / "unmuted.mp4"
    render_clip_reel(selections, unmuted_out, audio_path=music, mute_clip_audio=False, duck_gain_db=0.0)

    # With the clip's own audio at full gain (duck 0dB) vs muted entirely,
    # the muted render must be measurably quieter in the same window, proof
    # the mute flag actually suppresses clip audio rather than being a no-op.
    # (Summing two uncorrelated equal-amplitude tones raises RMS by ~3.01dB
    # (sqrt(2)), so 1.5dB is a safe margin above measurement noise while
    # still well below the fully-mixed expectation.)
    muted_db = _mean_volume_db(muted_out, 0.5, 4.0)
    unmuted_db = _mean_volume_db(unmuted_out, 0.5, 4.0)
    assert unmuted_db > muted_db + 1.5


@needs_ffmpeg
def test_atomic_write_replaces_existing_output_cleanly(tmp_path):
    clip = tmp_path / "a.mp4"
    _make_clip(clip, seconds=3.0, color="yellow")
    out = tmp_path / "reel.mp4"
    out.write_bytes(b"stale placeholder")

    selections = [
        {"clip_path": str(clip), "trim_in": 0.0, "trim_out": 3.0, "transition_after": "cut"},
    ]
    render_clip_reel(selections, out)

    assert out.exists()
    assert out.read_bytes() != b"stale placeholder"
    # No leftover temp file next to the final output.
    leftovers = list(tmp_path.glob("reel.mp4.tmp*"))
    assert leftovers == []


@needs_ffmpeg
def test_default_duck_gain_is_minus_15_db():
    assert DEFAULT_DUCK_GAIN_DB == -15.0


def test_transition_duration_is_short():
    # Short enough to read as a deliberate blend, not a lingering dissolve.
    assert 0 < TRANSITION_DURATION <= 0.5


@needs_ffmpeg
def test_crop_offset_shifts_which_side_of_a_landscape_source_is_kept(tmp_path):
    # A landscape source twice canvas width, left half red / right half
    # blue: a centered crop keeps a mix, crop_x=-1 must keep (mostly) the
    # left/red side, crop_x=+1 must keep (mostly) the right/blue side.
    # This is the real-render proof that a non-zero crop offset actually
    # changes what's on screen, not just the filter string.
    clip = tmp_path / "split.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"color=c=red:s={320}x{240}", "-f", "lavfi", "-i", f"color=c=blue:s={320}x{240}",
         "-filter_complex", "[0:v][1:v]hstack=inputs=2,loop=loop=-1:size=1:start=0",
         "-t", "1.5", "-pix_fmt", "yuv420p", str(clip)],
        check=True,
    )

    def _corner_colors(crop_x: float) -> tuple:
        selections = [{"clip_path": str(clip), "trim_in": 0.0, "trim_out": 1.0,
                        "transition_after": "cut", "crop_x": crop_x, "crop_y": 0.0}]
        out = tmp_path / f"reel_{crop_x}.mp4"
        render_clip_reel(selections, out)
        frame = tmp_path / f"frame_{crop_x}.png"
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-ss", "0.5", "-i", str(out),
             "-frames:v", "1", str(frame)], check=True,
        )
        from PIL import Image
        img = Image.open(frame).convert("RGB")
        return img.getpixel((5, img.size[1] // 2)), img.getpixel((img.size[0] - 5, img.size[1] // 2))

    left_edge_at_neg1, right_edge_at_neg1 = _corner_colors(-1.0)
    left_edge_at_pos1, right_edge_at_pos1 = _corner_colors(1.0)

    def _is_red(px):
        return px[0] > 150 and px[2] < 100

    def _is_blue(px):
        return px[2] > 150 and px[0] < 100

    assert _is_red(left_edge_at_neg1) and _is_red(right_edge_at_neg1), (
        "crop_x=-1 should keep the source's left (red) side across the frame"
    )
    assert _is_blue(left_edge_at_pos1) and _is_blue(right_edge_at_pos1), (
        "crop_x=+1 should keep the source's right (blue) side across the frame"
    )


@needs_ffmpeg
def test_crossfade_transition_renders_without_error(tmp_path):
    clip_a = tmp_path / "a.mp4"
    clip_b = tmp_path / "b.mp4"
    _make_clip(clip_a, seconds=6.0, color="red", freq=300)
    _make_clip(clip_b, seconds=6.0, color="blue", freq=800)

    selections = [
        {"clip_path": str(clip_a), "trim_in": 0.0, "trim_out": 4.0, "transition_after": "crossfade"},
        {"clip_path": str(clip_b), "trim_in": 0.0, "trim_out": 4.0, "transition_after": "cut"},
    ]
    out = tmp_path / "reel.mp4"

    render_clip_reel(selections, out)

    assert out.exists()
    # Two 4s segments joined by one 0.4s crossfade: total ~= 4 + 4 - 0.4 = 7.6s.
    assert abs(_probe_duration(out) - 7.6) < 0.5
