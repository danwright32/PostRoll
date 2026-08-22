"""Tests for the Friday clip reel's Phase 3 title-card overlay (plan #148,
issue #152): the event name as an animated reveal on the reel's opening
seconds, reusing the story template's font and drop-shadow technique.

render_title_card_image is pure PIL (no ffmpeg needed) and tested directly.
apply_title_card composites onto a real clip via ffmpeg and is skipped when
ffmpeg isn't on PATH, same pattern as test_render_clip_reel.py.
"""

from __future__ import annotations

import inspect
import shutil
import subprocess
from pathlib import Path

import pytest
from PIL import Image

from postroll.media.generate_story import CANVAS_H, CANVAS_W
from postroll.media.generate_title_card import (
    TITLE_CARD_FADE_SECONDS,
    TITLE_CARD_HOLD_SECONDS,
    TITLE_CARD_TOTAL_SECONDS,
    TitleCardError,
    apply_title_card,
    render_title_card_image,
)

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


#: x264 presets that turn off the decisions making its output reproducible
#: between builds: trellis quantisation, subpixel refinement above the cheap
#: levels, mixed and multiple reference frames (#811).
#:
#: Named rather than allowing a list of good ones, so a preset nobody has
#: considered is caught rather than waved through by absence from a registry
#: (L96). `medium` is ffmpeg's default and is what every other template's final
#: encode uses.
UNREPRODUCIBLE_PRESETS = ("ultrafast", "superfast", "veryfast", "faster", "fast")


def test_the_title_card_pass_does_not_ask_x264_for_a_fast_preset():
    """The one thing that made this template's reference frame drift (#811).

    This pass is the LAST encode the clip reel goes through, so it is what
    decides the pixels a reference frame is read from. It asked for
    `-preset veryfast`, and every other template's final encode asks for no
    preset at all, which is ffmpeg's `medium`.

    Measured on the runner, not argued: with `veryfast` the clip reel read 26
    of 2073600 pixels differing from the committed frame, in a 363x17 band at
    the top of the title's script lettering, reproducible to the pixel across
    four independent macos-15 jobs. With the preset dropped and `-crf 20` kept
    it read 0, on the same runner and the same ffmpeg 8.1.2_1. That is one
    variable, and it is this one. The nine other frames read 0 throughout.

    A source check rather than a rendered one, for the reason
    `test_font_loading.py` gives about the text shaper: the behaviour only
    appears when two different ffmpeg builds encode the same frames, which no
    single machine can do, so a rendered assertion here would be vacuous
    everywhere it runs (L177).
    """
    source = Path(inspect.getsourcefile(apply_title_card)).read_text(encoding="utf-8")

    asked = [preset for preset in UNREPRODUCIBLE_PRESETS
             if f'"{preset}"' in source]

    assert not asked, (
        f"the title card pass asks x264 for {asked}, which turns off the "
        "decisions that keep its output the same between builds. This is the "
        "clip reel's FINAL encode, so those pixels are what its reference frame "
        "is read from, and a fast preset is what put 26 of them outside the "
        "tolerance on CI while the other nine templates read 0 (#811). Leave "
        "the preset unset, which is ffmpeg's medium and what every other "
        "template's last pass uses.")


# ===================================================================
# The staging name both callers actually pass (#824).
#
# generate_media.py writes the titled encode to `reel_clip_titled.mp4.tmp`
# and render_friday_override.py to `<reel>.titled.tmp`, both deliberately
# not plain .mp4 so nothing globbing a day folder picks a half-written
# encode up as an asset. ffmpeg chooses its muxer from the filename unless
# it is told, and it can choose nothing from `.tmp`: every title card in the
# real app failed on the first ffmpeg argument, was caught, printed, and
# thrown away, so every Friday reel shipped untitled and nothing said so.
#
# The reference frame missed it because it hands apply_title_card a plain
# `.mp4` of its own, so the test exercised a filename production never uses
# (L143).
# ===================================================================

@needs_ffmpeg
def test_apply_title_card_writes_an_mp4_to_the_staging_name_its_callers_pass(tmp_path):
    clip = tmp_path / "clip.mp4"
    _make_clip(clip, seconds=3.0)
    staging = tmp_path / "reel_clip_titled.mp4.tmp"

    apply_title_card(clip, "Sing Play", staging, tmp_dir=tmp_path / "work")

    assert staging.exists()
    probed = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=format_name",
         "-of", "default=nk=1:nw=1", str(staging)],
        capture_output=True, text=True,
    )
    assert "mp4" in probed.stdout, (
        "the encode has to be an MP4 whatever the file is called, or the "
        f"staging name its callers pass produces nothing: {probed.stderr.strip()}")


# ===================================================================
# apply_title_card_in_place (#824): the one place that decides what
# happens when the finishing touch fails.
#
# Both callers used to hold their own copy of this, and both answered a
# failure by printing a line and carrying on. Keeping the reel is right.
# Answering with a REASON rather than a print is what lets each caller put it
# somewhere Dan reads, which a console line cannot do once the process ends.
# ===================================================================

@needs_ffmpeg
def test_apply_title_card_in_place_titles_the_reel_and_reports_nothing(tmp_path):
    from postroll.media.generate_title_card import apply_title_card_in_place

    reel = tmp_path / "reel_clip.mp4"
    _make_clip(reel, seconds=3.0)
    before = reel.read_bytes()
    staging = tmp_path / "reel_clip_titled.mp4.tmp"

    skipped = apply_title_card_in_place(reel, "Sing Play", staging_path=staging)

    assert skipped is None, f"a title card that worked has nothing to report: {skipped}"
    assert reel.read_bytes() != before, "the reel at the same path must be the titled one"
    assert not staging.exists(), "the staging file is working state, not an asset"


def test_apply_title_card_in_place_keeps_the_reel_and_names_the_failure(tmp_path, monkeypatch):
    import postroll.media.generate_title_card as card_mod

    reel = tmp_path / "reel_clip.mp4"
    reel.write_bytes(b"the reel three stages already built")
    before = reel.read_bytes()
    staging = tmp_path / "reel_clip_titled.mp4.tmp"

    def failing(video_path, event_name, output_path, **kwargs):
        # Half-written output, which is what a killed ffmpeg leaves behind: the
        # staging file existing must not read as a titled reel.
        Path(output_path).write_bytes(b"half an encode")
        raise TitleCardError("ffmpeg title card overlay failed: no such filter")

    monkeypatch.setattr(card_mod, "apply_title_card", failing)

    skipped = card_mod.apply_title_card_in_place(reel, "Sing Play", staging_path=staging)

    assert skipped, "a reel that shipped untitled has to say so"
    # The reason ffmpeg gave, not a flattened "something went wrong": two
    # different failures here need two different next moves.
    assert "no such filter" in skipped
    assert "title card" in skipped
    assert reel.read_bytes() == before, "the reel Stage 1/2/3 built must survive untouched"
    assert not staging.exists(), "a half-written encode must not be left on disk"
