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
    assert len(ffmpeg_cmds) == 1
    _assert_mux_contract(ffmpeg_cmds[0], requires_t=True)
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

    final = [c for c in cap.commands if c[0] == "ffmpeg"][-1]
    _assert_mux_contract(final, requires_t=False)
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

    final = [c for c in cap.commands if c[0] == "ffmpeg"][-1]
    _assert_mux_contract(final, requires_t=False)
    assert out.exists()


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

    final = [c for c in cap.commands if c[0] == "ffmpeg"][-1]
    assert "concat" in final  # the closing branch's final encode
    _assert_mux_contract(final, requires_t=True)
    assert out.exists()
