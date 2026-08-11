"""#298: text baked into a rendered reel must be readable against what is behind it.

Nothing measured this across a render. Two defects of exactly this kind have
shipped: white brand text on the cream mat, and a divider drop shadow streaking
the mat behind the colophon. Both passed the suite. Both were invisible in
stills, because a still of the first frame does not show a label that only
appears mid animation.

`tests/test_golden_frames.py` pulls ONE frame out of each encoded reel and
checks the single band whose regression was reported at the time. This samples
frames across the whole encode and checks every band each template draws ink
into, with the ink colour known, so "the text is not there at all" is told apart
from "the text is there and washed out".

The bands come from `postroll/media/text_regions.py`, which builds them from the
generators' own constants, so a moved masthead moves the check with it.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from PIL import Image

from conftest import needs_ffmpeg, needs_mac_fonts
from postroll.media import design_tokens as tokens
from postroll.media import frame_legibility as legibility
from postroll.media import generate_reel_morph as morph_mod
from postroll.media import generate_reel_scroll as scroll_mod
from postroll.media import generate_reel_slider as slider_mod
from postroll.media import text_regions
from postroll.media.frame_legibility import TextRegion


REPO_ROOT = Path(__file__).resolve().parent.parent
LOGO = str(REPO_ROOT / "postroll" / "assets" / "logo-black.png")

#: How many frames each reel is read at. Spread across the whole file, because
#: the placards crossfade and the labels slide: an element that is only wrong
#: halfway through is exactly what one frame cannot show.
SAMPLES = 12


# ── the measurement ──────────────────────────────────────────────────────────


def _canvas(background, ink=None, box=None) -> Image.Image:
    img = Image.new("RGB", (200, 60), background)
    if ink is not None:
        for y in range(box[1], box[3]):
            for x in range(box[0], box[2]):
                img.putpixel((x, y), ink)
    return img


def test_dark_ink_on_the_cream_mat_reads():
    region = TextRegion("ink", (0, 0, 200, 60), tokens.TEXT_DARK)
    frame = _canvas(tokens.CREAM, tokens.TEXT_DARK, (10, 20, 60, 40))

    assert legibility.illegible([frame], [region]) == []


def test_white_ink_on_the_cream_mat_is_reported_as_absent():
    # The defect itself. The text really is drawn; nothing of the colour the
    # template declares is anywhere on the canvas, which is what invisible looks
    # like from here.
    region = TextRegion("masthead", (0, 0, 200, 60), tokens.TEXT_DARK)
    frame = _canvas(tokens.CREAM, (255, 255, 255), (10, 20, 60, 40))

    failures = legibility.illegible([frame], [region])

    assert len(failures) == 1
    assert "appears in none" in failures[0]


def test_ink_too_close_to_its_background_is_reported_with_the_ratio():
    ink = (150, 148, 145)
    region = TextRegion("subtitle", (0, 0, 200, 60), ink)
    frame = _canvas((190, 188, 185), ink, (10, 20, 60, 40))

    failures = legibility.illegible([frame], [region])

    assert len(failures) == 1
    assert "to 1" in failures[0]


def test_a_band_where_the_ink_appears_in_only_some_frames_passes():
    # The placards crossfade through empty, so a frame between them has no ink
    # to measure. Calling that a failure would fire on every correct render.
    region = TextRegion("placard", (0, 0, 200, 60), tokens.ROSE_GOLD)
    drawn = _canvas(tokens.CREAM, tokens.ROSE_GOLD, (10, 20, 60, 40))
    empty = _canvas(tokens.CREAM)

    assert legibility.illegible([empty, drawn, empty], [region]) == []


def test_a_rule_crossing_the_band_does_not_decide_what_the_text_sits_on():
    # A hairline or a rose gold rule crossing a band is a few rows of pixels. A
    # check that took the darkest pixel as the background would read that rule
    # as the surface, and pass a label sitting on a mat it nearly matches.
    ink = tokens.WARM_MID
    nearly_the_same = (150, 135, 128)
    region = TextRegion("venue", (0, 0, 200, 60), ink)
    frame = _canvas(nearly_the_same, ink, (10, 20, 60, 40))
    for x in range(200):
        frame.putpixel((x, 5), (0, 0, 0))

    failures = legibility.illegible([frame], [region])

    assert len(failures) == 1, "ink on a mat it nearly matches has to fail"
    assert "to 1" in failures[0]


def test_no_frames_at_all_is_an_error_rather_than_a_pass():
    # An empty sample is what a failed extraction returns, and it reads exactly
    # like a clean render (LESSONS.md L98).
    with pytest.raises(ValueError):
        legibility.illegible([], [TextRegion("x", (0, 0, 10, 10), tokens.CREAM)])


def test_a_logo_declares_the_colour_it_actually_draws_in():
    assert legibility.logo_ink(LOGO) == (0, 0, 0)


def test_the_contrast_ratio_matches_the_wcag_extremes():
    assert legibility.contrast_ratio((0, 0, 0), (255, 255, 255)) == pytest.approx(21, abs=0.01)
    assert legibility.contrast_ratio(tokens.CREAM, tokens.CREAM) == pytest.approx(1.0)


# ── the registry covers every template, in both directions ───────────────────


def _video_templates() -> set[str]:
    """The templates that render a moving picture, from the versions table."""
    return {name for name in tokens.MEDIA_DESIGN_VERSIONS if name.startswith("reel_")}


def test_every_reel_template_is_either_checked_or_excused():
    checked = {"reel_morph", "reel_slider", "reel_scroll"}
    accounted = checked | set(text_regions.UNCHECKED_TEMPLATES)
    missing = sorted(_video_templates() - accounted)

    assert not missing, (
        "these reels render text and nothing here says whether it can be read: "
        f"{missing}. Give them bands in text_regions.py, or a stated reason in "
        "UNCHECKED_TEMPLATES.")


def test_nothing_is_excused_that_is_also_checked():
    assert not ({"reel_morph", "reel_slider", "reel_scroll"}
                & set(text_regions.UNCHECKED_TEMPLATES))


def test_the_template_scan_actually_finds_the_reels():
    # Guards the derivation above: a filter matching nothing would make the
    # completeness test pass with total confidence.
    assert len(_video_templates()) >= 5, sorted(_video_templates())


def test_every_band_sits_inside_the_canvas_it_measures():
    # A band running off the canvas crops to nothing, and a region of no pixels
    # would be read as "the ink is not here" on every frame forever.
    for regions, width, height in [
        (text_regions.morph_regions(624, LOGO), morph_mod.CANVAS_W, morph_mod.CANVAS_H),
        (text_regions.slider_regions(LOGO), slider_mod.CANVAS_W, slider_mod.CANVAS_H),
        (text_regions.scroll_regions(), scroll_mod.CANVAS_W, scroll_mod.CANVAS_H),
    ]:
        assert regions
        for region in regions:
            left, top, right, bottom = region.box
            assert 0 <= left < right <= width, region
            assert 0 <= top < bottom <= height, region


# ── the reels themselves, read back out of the encoded file ──────────────────


@pytest.fixture
def photos(tmp_path) -> list[str]:
    """Structured stand-ins, not flat colour: a flat photo makes every band it
    touches trivially uniform and hides a placement regression."""
    out = []
    for seed in range(10):
        path = tmp_path / f"p{seed}.jpg"
        img = Image.new("RGB", (2000, 1332))
        pixels = img.load()
        for y in range(1332):
            for x in range(0, 2000, 4):
                shade = ((x // 40) + (y // 40) + seed) % 3
                colour = [(150, 96, 74), (66, 52, 48), (196, 158, 120)][shade]
                for dx in range(4):
                    pixels[x + dx, y] = colour
        img.save(path, "JPEG", quality=92)
        out.append(str(path))
    return out


@pytest.fixture
def silent_audio(tmp_path) -> str:
    """A local silent track: handed no audio the generators fetch from Jamendo,
    so a test that passed None would call a third-party service on every run."""
    path = tmp_path / "silence.m4a"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
         "-t", "45", "-c:a", "aac", str(path)],
        check=True, capture_output=True)
    return str(path)


@needs_ffmpeg
@needs_mac_fonts
def test_the_tuesday_reel_reads_all_the_way_through(photos, silent_audio, tmp_path):
    video = morph_mod.generate_reel_morph(
        raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
        output_path=str(tmp_path / "morph.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        logo_path=LOGO)

    frames = legibility.sample_frames(video, SAMPLES)
    # The print's height is set from the photograph's aspect during the render,
    # and the placard hangs off the bottom of the print, so it is read back from
    # the module rather than guessed.
    regions = text_regions.morph_regions(morph_mod._PRINT_H, LOGO)

    assert legibility.illegible(frames, regions) == []


@needs_ffmpeg
@needs_mac_fonts
def test_the_three_photo_tuesday_reel_reads_all_the_way_through(
        photos, silent_audio, tmp_path):
    video = slider_mod.generate_reel_slider(
        raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
        output_path=str(tmp_path / "slider.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        logo_path=LOGO)

    frames = legibility.sample_frames(video, SAMPLES)

    assert legibility.illegible(frames, text_regions.slider_regions(LOGO)) == []


@needs_ffmpeg
@needs_mac_fonts
def test_the_thursday_reel_header_reads_all_the_way_through(
        photos, silent_audio, tmp_path):
    # A short scroll rather than the shipping 40 seconds. `scroll_duration` is a
    # real parameter of the generator, not a seam opened for the test, and the
    # header chrome under test does not change with the duration.
    video = scroll_mod.generate_reel_scroll(
        photo_paths=photos, audio_path=silent_audio,
        output_path=str(tmp_path / "scroll.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        seed=298, scroll_duration=4.0, logo_path=LOGO)

    frames = legibility.sample_frames(video, SAMPLES)

    assert legibility.illegible(frames, text_regions.scroll_regions()) == []


@needs_ffmpeg
@needs_mac_fonts
def test_a_white_masthead_on_the_cream_mat_fails_the_tuesday_reel(
        photos, silent_audio, tmp_path, monkeypatch):
    """The guard seen refusing on a real encoded render (LESSONS.md L1).

    The template is made to draw its masthead white, which is the defect that
    shipped, and the check has to report it from the encoded file.
    """
    monkeypatch.setattr(morph_mod, "TEXT_DARK", (255, 255, 255))
    video = morph_mod.generate_reel_morph(
        raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
        output_path=str(tmp_path / "white.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        logo_path=LOGO)

    frames = legibility.sample_frames(video, SAMPLES)
    failures = legibility.illegible(frames, text_regions.morph_regions(
        morph_mod._PRINT_H, LOGO))

    assert any("masthead" in f for f in failures), failures


@needs_ffmpeg
def test_a_file_with_no_duration_is_an_error_rather_than_zero_frames(tmp_path):
    empty = tmp_path / "not-a-video.mp4"
    empty.write_bytes(b"")

    with pytest.raises(RuntimeError):
        legibility.sample_frames(empty, 2)
