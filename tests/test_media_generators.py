"""Tests for the media generators: crop bias parity and ffmpeg command
construction.

ffmpeg is never actually run. subprocess.run is replaced with a capture
that records every command and touches the output file, so the assertions
pin exactly the flags whose absence caused real bugs: duration caps,
explicit stream selection, and atomic temp encodes.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from postroll.media import generate_reel_morph as morph_mod
from postroll.media import generate_reel_screen as screen_mod
from postroll.media import generate_reel_scroll as scroll_mod
from postroll.media import generate_reel_slider as slider_mod
from postroll.media.generate_collage import crop_to_fill
from postroll.ai import swap_reel_audio as swap_mod


# ===================================================================
# crop_to_fill — 0.5 Y bias parity with the SwiftUI editor
# ===================================================================


def _gradient_photo() -> Image.Image:
    """100x200 photo whose red channel encodes the row index, so the
    first output row reveals exactly where the crop window started."""
    img = Image.new("RGB", (100, 200))
    px = img.load()
    for y in range(200):
        for x in range(100):
            px[x, y] = (y, 0, 0)
    return img


def test_crop_centered_uses_half_overflow():
    out = crop_to_fill(_gradient_photo(), 100, 100)
    assert out.size == (100, 100)
    # overflow is 100 rows; centred crop starts at 50
    assert out.getpixel((0, 0))[0] == 50


def test_crop_full_drag_reaches_top_edge():
    out = crop_to_fill(_gradient_photo(), 100, 100, crop_offset_y=-1.0)
    assert out.getpixel((0, 0))[0] == 0


def test_crop_full_drag_reaches_bottom_edge():
    # top = overflow * (0.5 + offset * 0.5) = full 100 rows at offset 1.
    # The old 0.4 bias (the SwiftUI parity bug) would start at 90 instead,
    # so this pins the full drag range contract.
    out = crop_to_fill(_gradient_photo(), 100, 100, crop_offset_y=1.0)
    assert out.getpixel((0, 0))[0] == 100


def test_crop_x_axis_uses_same_bias():
    img = Image.new("RGB", (200, 100))
    px = img.load()
    for y in range(100):
        for x in range(200):
            px[x, y] = (x, 0, 0)
    out = crop_to_fill(img, 100, 100, crop_offset_x=1.0)
    assert out.getpixel((0, 0))[0] == 100


# ===================================================================
# ffmpeg command construction
# ===================================================================


class FFmpegCapture:
    """Stands in for subprocess.run: records commands, touches the output
    file for ffmpeg calls, and answers ffprobe queries with fixed values."""

    def __init__(self):
        self.commands: list[list[str]] = []

    def __call__(self, cmd, **kwargs):
        self.commands.append(list(cmd))
        if cmd[0] == "ffmpeg":
            Path(cmd[-1]).touch()
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
        if cmd[0] == "ffprobe":
            joined = " ".join(cmd)
            if "width,height" in joined:
                return subprocess.CompletedProcess(cmd, 0, stdout="640,480\n", stderr="")
            return subprocess.CompletedProcess(cmd, 0, stdout="10.0\n", stderr="")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")


def _photo(path: Path, size=(400, 300)) -> Path:
    Image.new("RGB", size, (90, 70, 60)).save(path)
    return path


def _assert_audio_fit_pass(commands: list[list[str]]):
    """Every reel mux is now preceded by an audio-fit pass that renders the
    track to the reel's exact length (looping short clips with crossfaded
    seams). Returns the ffmpeg commands for further assertions."""
    ffmpeg = [c for c in commands if c[0] == "ffmpeg"]
    assert any(c[-1].endswith(".wav") for c in ffmpeg), \
        "expected an audio-fit pass rendering a fitted .wav before the mux"
    return ffmpeg


def _assert_mux_contract(cmd: list[str], *, requires_t: bool):
    """The contract every reel mux must satisfy."""
    # Explicit stream selection so MP3 cover art can't become the video
    assert "-map" in cmd
    assert "0:v:0" in cmd
    assert "1:a:0" in cmd
    # Bounded duration: -t or -shortest, never open ended
    if requires_t:
        assert "-t" in cmd
    else:
        assert "-t" in cmd or "-shortest" in cmd
    # Atomic encode: write to a temp name, rename into place on success
    assert cmd[-1].endswith(".tmp.mp4")


def test_scroll_reel_ffmpeg_command(tmp_path, monkeypatch):
    photos = [_photo(tmp_path / f"p{i}.jpg") for i in range(2)]
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    monkeypatch.setattr(scroll_mod, "FPS", 2)
    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        result = scroll_mod.generate_reel_scroll(
            [str(p) for p in photos], str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
            scroll_duration=2.0,
        )

    ffmpeg_cmds = [c for c in cap.commands if c[0] == "ffmpeg"]
    # Two ffmpeg passes now: fit/loop the audio to the reel length, then encode.
    assert len(ffmpeg_cmds) == 2
    # The audio-fit pass renders a WAV; the final pass is the reel mux.
    assert ffmpeg_cmds[0][-1].endswith("audio_fit.wav")
    _assert_mux_contract(ffmpeg_cmds[-1], requires_t=True)
    assert out.exists()
    assert result == str(out)


def test_slider_reel_ffmpeg_command(tmp_path, monkeypatch):
    raw = _photo(tmp_path / "raw.jpg")
    edit = _photo(tmp_path / "edit.jpg")
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    monkeypatch.setattr(slider_mod, "FPS", 1)
    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        slider_mod.generate_reel_slider(
            str(raw), str(edit), str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    _assert_mux_contract(final, requires_t=True)
    # Fitted audio is the exact reel length, so the reel is bounded by -t and
    # no longer relies on -shortest (which would cut the reel to a short track).
    assert "-shortest" not in final
    assert out.exists()


def test_morph_reel_ffmpeg_command(tmp_path, monkeypatch):
    raw = _photo(tmp_path / "raw.jpg")
    edit = _photo(tmp_path / "edit.jpg")
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    monkeypatch.setattr(morph_mod, "FPS", 1)
    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        morph_mod.generate_reel_morph(
            str(raw), str(edit), str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    _assert_mux_contract(final, requires_t=True)
    assert "-shortest" not in final
    assert out.exists()


def test_scroll_reel_short_strip_pads_instead_of_black_band(tmp_path, monkeypatch):
    """With a handful of photos the strip is shorter than the canvas. The
    crop must not read past the strip bottom (black band), and a 40 second
    motionless scroll must collapse to a short hold."""
    photos = [_photo(tmp_path / f"p{i}.jpg", size=(1200, 400)) for i in range(2)]
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    monkeypatch.setattr(scroll_mod, "FPS", 2)
    sampled = {}

    class FrameInspectingCapture(FFmpegCapture):
        def __call__(self, cmd, **kwargs):
            if cmd[0] == "ffmpeg":
                # Frames still exist while ffmpeg runs; sample the band
                # between the content bottom and the footer chrome.
                from PIL import Image as PILImage

                pattern = next(a for a in cmd if "frame_%05d" in a)
                frames = sorted(Path(pattern).parent.glob("frame_*.png"))
                with PILImage.open(frames[-1]) as f:
                    sampled["pixel"] = f.getpixel(
                        (scroll_mod.CANVAS_W // 2,
                         scroll_mod.CANVAS_H - scroll_mod.FOOTER_H - 10)
                    )
            return super().__call__(cmd, **kwargs)

    cap = FrameInspectingCapture()
    with patch("subprocess.run", new=cap):
        scroll_mod.generate_reel_scroll(
            [str(p) for p in photos], str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
        )

    # No black band: the padded area is the cream background
    assert sampled["pixel"] != (0, 0, 0)
    # The scroll phase collapsed (4s hold + 1s end hold + 5s closing slot),
    # far below the default 40s scroll plus tail
    cmd = [c for c in cap.commands if c[0] == "ffmpeg"][0]
    t_value = float(cmd[cmd.index("-t") + 1])
    assert t_value <= 10.0


def test_screen_reel_closing_path_caps_duration(tmp_path):
    """The closing frame branch shipped without -t once: the container ran
    for the whole music track. Pin the cap and the mux contract."""
    rec = tmp_path / "rec.mp4"
    rec.write_bytes(b"fake video")
    raw = _photo(tmp_path / "raw.jpg")
    edit = _photo(tmp_path / "edit.jpg")
    closing = tmp_path / "closing.png"
    Image.new("RGB", (1080, 1920), (240, 230, 215)).save(closing)
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        screen_mod.generate_reel_screen(
            str(rec), str(raw), str(edit), str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
            closing_frame_path=str(closing),
            target_duration=5.0,
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    assert "concat" in final  # the closing branch's final encode
    _assert_mux_contract(final, requires_t=True)
    assert out.exists()


def test_screen_reel_simple_path_drops_shortest_with_fitted_audio(tmp_path):
    """The non-closing branch used -shortest, which truncates the reel to a
    short track. With the audio fitted to length it must be bounded by -t and
    drop -shortest."""
    rec = tmp_path / "rec.mp4"
    rec.write_bytes(b"fake video")
    raw = _photo(tmp_path / "raw.jpg")
    edit = _photo(tmp_path / "edit.jpg")
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        screen_mod.generate_reel_screen(
            str(rec), str(raw), str(edit), str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
            target_duration=5.0,
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    _assert_mux_contract(final, requires_t=True)
    assert "-shortest" not in final
    assert out.exists()


def test_swap_reel_audio_fits_user_audio_to_video(tmp_path):
    """Swapping in a user-provided track fits it to the video length first
    (looping short clips), then re-muxes with the video stream copied."""
    reel = tmp_path / "reel.mp4"
    reel.write_bytes(b"fake video")
    audio = tmp_path / "user.mp3"
    audio.write_bytes(b"fake mp3")

    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        result = swap_mod.swap_reel_audio(
            str(reel), shoot_type="performance", pieces=[], audio_file=str(audio),
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    # Video stream copied, fitted audio mapped in, bounded by -t.
    assert "copy" in final
    assert "1:a:0" in final
    assert "-t" in final
    assert result["reel"] == str(reel.resolve())
