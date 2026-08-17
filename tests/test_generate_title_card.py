"""Tests for the Friday clip reel's Phase 3 title-card overlay (plan #148,
issue #152): the event name as an animated reveal on the reel's opening
seconds, reusing the story template's font and drop-shadow technique.

render_title_card_image is pure PIL (no ffmpeg needed) and tested directly.
apply_title_card composites onto a real clip via ffmpeg and is skipped when
ffmpeg isn't on PATH, same pattern as test_render_clip_reel.py.
"""

from __future__ import annotations

import shutil
import subprocess

import pytest
from PIL import Image, ImageStat

from postroll.media.generate_story import CANVAS_H, CANVAS_W
from postroll.media.generate_title_card import (
    TITLE_CARD_FADE_SECONDS,
    TITLE_CARD_HOLD_SECONDS,
    TITLE_CARD_TOTAL_SECONDS,
    TitleCardError,
    apply_title_card,
    render_title_card_image,
)

from conftest import needs_mac_fonts

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg/ffprobe not installed")


# ===================================================================
# Timing (Dan's call, 2026-07-09): fade in, hold, fade out, ~2s total.
# ===================================================================

def test_total_on_screen_duration_is_about_two_seconds():
    assert TITLE_CARD_TOTAL_SECONDS == pytest.approx(2.0)


def test_fade_and_hold_sum_to_the_total():
    assert TITLE_CARD_FADE_SECONDS * 2 + TITLE_CARD_HOLD_SECONDS == pytest.approx(TITLE_CARD_TOTAL_SECONDS)


# ===================================================================
# render_title_card_image: pure PIL, no ffmpeg needed
# ===================================================================

def test_title_card_image_is_full_canvas_size_and_transparent(tmp_path):
    out = tmp_path / "title.png"
    render_title_card_image("Sing Play", out)

    img = Image.open(out)
    assert img.mode == "RGBA"
    assert img.size == (CANVAS_W, CANVAS_H)
    # A far corner, well away from any text or shadow, must stay fully
    # transparent: this overlay sits on top of live video, not a solid card.
    assert img.getpixel((5, 5))[3] == 0


def test_title_card_image_has_visible_text_pixels(tmp_path):
    out = tmp_path / "title.png"
    render_title_card_image("Sing Play", out)

    img = Image.open(out)
    alphas = [px[3] for px in img.getdata()]
    assert max(alphas) > 0, "no non-transparent pixels: text was never drawn"


@needs_mac_fonts
def test_the_type_is_drawn_light_enough_to_sit_over_footage(tmp_path):
    """The rule that makes this card readable at all (#665).

    Gated on the macOS fonts, like every other check that renders real type:
    the script face is a system font, and without it the card comes back with
    one fully opaque pixel in it. Found on a Linux runner, by the refusal below
    rather than by a green pass over an empty measurement.

    The card is transparent, so nothing here can measure it against a
    background: its legibility is decided when it is composited over the reel,
    and `test_golden_frames.py` measures that on a real encoded frame. What can
    be checked without rendering a reel is the rule the design rests on, that
    the type is LIGHT, because it is laid over photographic footage whose mid
    tones are dark.

    Measured on the type's own pixels, not on the card as a whole: the card also
    draws a blurred black shadow and two rose gold rules, and either would drag
    a whole-image average down while the type stayed white. Fully opaque is what
    separates them, since the shadow is blurred to a fraction of full alpha and
    the rules are drawn at 170.
    """
    out = tmp_path / "title.png"
    render_title_card_image("Sing Play", out)

    card = Image.open(out).convert("RGBA")
    grey = card.convert("L")
    alpha = card.getchannel("A")
    type_mask = alpha.point(lambda a: 255 if a >= 250 else 0)

    drawn = type_mask.histogram()[255]
    assert drawn > 500, (
        f"only {drawn} fully opaque pixels, so there is no type here to "
        f"measure and this check would pass on an empty card")

    brightness = ImageStat.Stat(grey, mask=type_mask).mean[0]
    assert brightness > 200, (
        f"the type is drawn at brightness {brightness:.0f}, which is not light "
        f"enough to read over footage; this card carries no background of its "
        f"own, so a dark title is invisible wherever it lands")


def test_title_card_image_handles_long_event_names_without_crashing(tmp_path):
    out = tmp_path / "title.png"
    render_title_card_image("An Extremely Long Event Name That Needs Wrapping Across Lines", out)

    assert out.exists()


# ===================================================================
# apply_title_card: real ffmpeg compositing
# ===================================================================

def _make_clip(path, seconds=4.0, color="gray"):
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"color=c={color}:s=1080x1920:d={seconds}", str(path)],
        check=True,
    )


def _probe_duration(path):
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True,
    )
    return float(proc.stdout.strip())


def _frame_at(video_path, t, out_path):
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-ss", str(t), "-i", str(video_path),
         "-frames:v", "1", str(out_path)],
        check=True,
    )
    return Image.open(out_path).convert("RGB")


def _max_abs_diff(img_a, img_b, box):
    # Max, not mean: the title text only covers a small fraction of the
    # sampled region, so an area-averaged diff is diluted by empty
    # background almost to noise level even when the text is clearly
    # visible. Max per-channel diff picks up the brightest text pixels
    # regardless of how much empty space surrounds them.
    a = img_a.crop(box)
    b = img_b.crop(box)
    return max(
        abs(ca - cb)
        for pa, pb in zip(a.getdata(), b.getdata())
        for ca, cb in zip(pa, pb)
    )


@needs_ffmpeg
def test_apply_title_card_preserves_video_duration(tmp_path):
    clip = tmp_path / "clip.mp4"
    _make_clip(clip, seconds=4.0)
    out = tmp_path / "titled.mp4"

    apply_title_card(clip, "Sing Play", out, tmp_dir=tmp_path / "work")

    assert out.exists()
    assert abs(_probe_duration(out) - 4.0) < 0.3


@needs_ffmpeg
def test_apply_title_card_visibly_changes_the_upper_third_during_the_hold(tmp_path):
    clip = tmp_path / "clip.mp4"
    _make_clip(clip, seconds=4.0)
    out = tmp_path / "titled.mp4"

    apply_title_card(clip, "Sing Play", out, tmp_dir=tmp_path / "work")

    baseline_frame = _frame_at(clip, 1.0, tmp_path / "baseline.png")
    titled_frame = _frame_at(out, 1.0, tmp_path / "titled_frame.png")

    # Upper third of a 1080x1920 canvas: where the title card is anchored.
    box = (0, 0, 1080, 640)
    diff = _max_abs_diff(baseline_frame, titled_frame, box)
    assert diff > 100, f"upper third barely changed during the hold window (max diff={diff})"


@needs_ffmpeg
def test_apply_title_card_frame_matches_original_after_fade_out(tmp_path):
    clip = tmp_path / "clip.mp4"
    _make_clip(clip, seconds=4.0)
    out = tmp_path / "titled.mp4"

    apply_title_card(clip, "Sing Play", out, tmp_dir=tmp_path / "work")

    late_t = TITLE_CARD_TOTAL_SECONDS + 1.0
    baseline_frame = _frame_at(clip, late_t, tmp_path / "baseline_late.png")
    titled_frame = _frame_at(out, late_t, tmp_path / "titled_late.png")

    box = (0, 0, 1080, 640)
    diff = _max_abs_diff(baseline_frame, titled_frame, box)
    assert diff < 20, f"frame still differs well after the title card should have faded out (max diff={diff})"


@needs_ffmpeg
def test_apply_title_card_raises_on_missing_source_video(tmp_path):
    with pytest.raises(TitleCardError):
        apply_title_card(tmp_path / "does-not-exist.mp4", "Sing Play", tmp_path / "out.mp4")
