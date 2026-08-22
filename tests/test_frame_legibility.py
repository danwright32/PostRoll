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
from postroll.media import program_plate as plate_mod
from postroll.media import text_regions
from postroll.media.frame_legibility import MovingTextRegion, TextRegion
from reel_render_fixtures import LOGO, PHOTO_SIZE, SAMPLES

# The Thursday scrolling reel's checks live in
# `test_thursday_reel_legibility.py` since #512: this file was a shard on its
# own and nothing could divide it further while it was one file. What is left
# here is the measurement itself, the template registry, and the Tuesday reel.
#
# Every check in this file renders a real reel and reads pixels back, which is
# where the suite's time goes. `make test-python-fast` deselects it; CI and
# `make test-python` still run it (#413).
pytestmark = pytest.mark.slow



REPO_ROOT = Path(__file__).resolve().parent.parent


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


#: Photograph shapes the Tuesday reel's bands are checked against.
#:
#: A single hardcoded print height (624, the 3:2 case) used to stand here, and
#: it made this guard structurally unable to see #322: a 2:3 portrait produced a
#: 1404px print and put the caption at y=1920, off the bottom of the canvas,
#: while this test went on measuring a landscape one. A fixture that only ever
#: holds one shape takes the same branch forever (L101).
PHOTO_SHAPES = [
    (3000, 2000, "3:2 landscape"),
    (2000, 2000, "square"),
    (2000, 2500, "4:5 portrait"),
    (2000, 3000, "2:3 portrait"),
    # Beyond anything Dan shoots, and the only shape whose UNCLAMPED band would
    # leave the canvas: at 2:3 the caption clears the canvas but overruns the
    # colophon rule, which is a different guard (tests/test_print_rect.py).
    (1000, 3000, "extreme portrait"),
]


def test_every_band_sits_inside_the_canvas_it_measures():
    # A band running off the canvas crops to nothing, and a region of no pixels
    # would be read as "the ink is not here" on every frame forever.
    cases = [
        (text_regions.morph_regions(morph_mod.print_rect((w, h))[3], LOGO),
         morph_mod.CANVAS_W, morph_mod.CANVAS_H, name)
        for w, h, name in PHOTO_SHAPES
    ] + [
    ] + [
        (text_regions.slider_regions(LOGO, slider_mod.print_rect((w, h))[3]),
         slider_mod.CANVAS_W, slider_mod.CANVAS_H, f"slider {name}")
        for w, h, name in PHOTO_SHAPES
    ] + [
        (text_regions.scroll_regions(), scroll_mod.CANVAS_W, scroll_mod.CANVAS_H,
         "scroll"),
    ]
    for regions, width, height, name in cases:
        assert regions, name
        for region in regions:
            left, top, right, bottom = region.box
            assert 0 <= left < right <= width, (name, region)
            assert 0 <= top < bottom <= height, (name, region)


# ── ink that moves through the frame (#306) ──────────────────────────────────

# The Thursday reel's colophon is baked into the scrolling strip rather than
# pinned to the frame, so it passes through a different band on every frame. A
# fixed rectangle cannot address it, and a band big enough to catch it wherever
# it lands would take its background reading from whatever photography was
# passing at the time.


def _moving_canvas(width=200, height=120) -> Image.Image:
    """A frame of cream mat with a strip of photography across the middle."""
    img = Image.new("RGB", (width, height), tokens.CREAM)
    for y in range(40, 80):
        for x in range(width):
            img.putpixel((x, y), (66, 52, 48))
    return img


def _paint(img, box, colour):
    for y in range(box[1], box[3]):
        for x in range(box[0], box[2]):
            img.putpixel((x, y), colour)


def _paint_mark(img, box, colour):
    """A stand-in wordmark: strokes with mat between them.

    Not a solid bar. A wordmark leaves most of its own row as mat, which is
    exactly what tells it apart from a passage of photography, so a solid block
    would be testing a shape the check is right to reject.
    """
    for y in range(box[1], box[3]):
        for x in range(box[0], box[2], 8):
            img.putpixel((x, y), colour)
            img.putpixel((x + 1, y), colour)


def _moving_region(**overrides) -> MovingTextRegion:
    fields = dict(name="mark", search=(0, 0, 200, 120), ink=(0, 0, 0),
                  backdrop=tokens.CREAM)
    fields.update(overrides)
    return MovingTextRegion(**fields)


def test_the_band_is_found_where_the_mark_actually_is():
    frame = _moving_canvas()
    _paint_mark(frame, (20, 95, 180, 105), (0, 0, 0))

    assert legibility.find_ink_band(frame, _moving_region()) == (0, 95, 200, 105)


def test_a_frame_the_mark_has_scrolled_out_of_has_no_band():
    # Most frames of a scroll, and the reason a missing band cannot be a
    # failure on its own.
    assert legibility.find_ink_band(_moving_canvas(), _moving_region()) is None


def test_dark_photography_is_not_mistaken_for_the_mark():
    # The whole risk of searching for ink rather than declaring where it is.
    # The band of photography here is darker than the mat and spans the search
    # area, and it is not the wordmark.
    frame = _moving_canvas()
    _paint(frame, (0, 50, 200, 70), (0, 0, 0))

    assert legibility.find_ink_band(frame, _moving_region()) is None, (
        "a passage of dark photography answered the question the mark was "
        "supposed to answer")


def test_the_longest_run_wins_rather_than_the_span_between_two():
    # Two separate marks would otherwise produce one band stretched across the
    # clean mat between them, and the median of that band is mat, which reads
    # as a comfortable ratio for text that is mostly not there.
    frame = _moving_canvas()
    _paint_mark(frame, (20, 10, 180, 13), (0, 0, 0))
    _paint_mark(frame, (20, 95, 180, 110), (0, 0, 0))

    assert legibility.find_ink_band(frame, _moving_region()) == (0, 95, 200, 110)


def test_a_search_area_with_no_area_is_an_error():
    with pytest.raises(ValueError):
        legibility.find_ink_band(_moving_canvas(),
                                 _moving_region(search=(50, 60, 50, 60)))


def test_a_mark_no_frame_shows_is_reported():
    # The wrong file (white on cream), and equally a colophon that never made
    # it into the strip. Either way the check proved nothing, and reporting
    # nothing would be a pass nobody measured (L98).
    frames = [_moving_canvas() for _ in range(4)]

    failures = legibility.illegible_moving(frames, [_moving_region()])

    assert len(failures) == 1
    assert "never shows it" in failures[0], failures


def test_a_mark_only_some_frames_show_reads_fine():
    on_screen = _moving_canvas()
    _paint_mark(on_screen, (20, 95, 180, 105), (0, 0, 0))
    frames = [_moving_canvas(), on_screen, _moving_canvas()]

    assert legibility.illegible_moving(frames, [_moving_region()]) == []


def test_a_mark_too_close_to_its_mat_is_reported_with_the_ratio():
    # Light enough against the cream to fall under the bar, while still far
    # enough from it that the two can be told apart at all. An ink closer than
    # the tolerance is not a washed-out mark, it is an invisible one, and it is
    # reported as absent instead, which is the case above.
    frame = _moving_canvas()
    washed = (150, 150, 150)
    _paint_mark(frame, (20, 95, 180, 105), washed)

    failures = legibility.illegible_moving(
        frames=[frame], regions=[_moving_region(ink=washed)])

    assert len(failures) == 1
    assert "to 1" in failures[0], failures


def test_no_frames_at_all_is_an_error_for_moving_ink_too():
    with pytest.raises(ValueError):
        legibility.illegible_moving([], [_moving_region()])


def test_the_colophon_search_area_sits_inside_the_scroll_canvas():
    for region in text_regions.scroll_moving_regions(LOGO):
        left, top, right, bottom = region.search
        assert 0 <= left < right <= scroll_mod.CANVAS_W, region
        assert 0 <= top < bottom <= scroll_mod.CANVAS_H, region


def test_the_colophon_search_starts_below_the_header():
    # The header carries its own dark ink on the same cream. A search that
    # found the title instead would report a comfortable reading on every
    # frame while the colophon was missing entirely.
    region = text_regions.scroll_moving_regions(LOGO)[0]

    assert region.search[1] >= scroll_mod.CHROME_BOTTOM_Y


# ── the reels themselves, read back out of the encoded file ──────────────────


@needs_ffmpeg
@needs_mac_fonts
def test_the_tuesday_reel_reads_all_the_way_through(
        photos, silent_audio, closing_graphic, tmp_path):
    # WITH the closing graphic, which is the only shape the app ever produces.
    # Rendered without one, the last four and a half seconds of this file are a
    # held plate: the crossfade and the closing hold do not exist to be checked,
    # so the test covered a reel nobody ships (#335).
    video = morph_mod.generate_reel_morph(
        raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
        output_path=str(tmp_path / "morph.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        closing_frame_path=closing_graphic, logo_path=LOGO)

    # The reel's own phases, not the whole file (#777).
    #
    # The last few seconds are the closing hold, which is a BEFORE/AFTER
    # graphic: a different template, with its own layout. Judging it against
    # this reel's declared bands measures one template's picture against
    # another template's expectations, and it passed only because the two
    # happened to put plain mat at the same coordinates. Moving the
    # before/after colophon in #753 made the placard band land on that
    # graphic's photograph and read 1.76 to 1 (L135).
    #
    # The closing hold has its own checks: the two below this one.
    frames = legibility.sample_frames_between(
        video, 0.0, morph_mod.CLOSING_CROSSFADE_START, SAMPLES)
    # The print's height is set from the photograph's aspect during the render,
    # and the placard hangs off the bottom of the print, so it is read back from
    # the module rather than guessed.
    regions = text_regions.morph_regions(morph_mod.print_rect(PHOTO_SIZE)[3], LOGO)

    assert legibility.illegible(frames, regions) == []


@needs_ffmpeg
@needs_mac_fonts
def test_the_three_photo_tuesday_reel_reads_all_the_way_through(
        photos, silent_audio, closing_graphic, tmp_path):
    # A B&W is required now: this reel renders three states and nothing in the
    # app reaches it without one (#164, #324). The test used to pass none, so
    # despite its name it rendered the two-photo reel and proved nothing about
    # the mode it is named for.
    video = slider_mod.generate_reel_slider(
        raw_path=photos[0], edit_path=photos[1], bw_path=photos[2],
        audio_path=silent_audio,
        output_path=str(tmp_path / "slider.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        closing_frame_path=closing_graphic, logo_path=LOGO)

    # The reel's own phases, for the reason the morph test above gives (#777):
    # the last few seconds are a before/after graphic, and this reel's bands say
    # nothing about it.
    frames = legibility.sample_frames_between(
        video, 0.0, slider_mod.CLOSING_CROSSFADE_START, SAMPLES)
    regions = text_regions.slider_regions(
        LOGO, slider_mod.print_rect(PHOTO_SIZE)[3])

    assert legibility.illegible(frames, regions) == []


@needs_ffmpeg
@needs_mac_fonts
def test_a_white_masthead_on_the_cream_mat_fails_the_tuesday_reel(
        photos, silent_audio, tmp_path, monkeypatch):
    """The guard seen refusing on a real encoded render (LESSONS.md L1).

    The template is made to draw its masthead white, which is the defect that
    shipped, and the check has to report it from the encoded file.

    Patched on `program_plate`, which is where the masthead is drawn. It used to
    be patched on the reel module, and when the plate moved out that patch went
    on being applied to a name nothing read, so the test rendered a perfectly
    correct reel and asserted a failure that could no longer happen. It went red
    and said so, which is the whole reason a seen-to-fail test is written
    against a real render rather than a mock.
    """
    monkeypatch.setattr(plate_mod, "TEXT_DARK", (255, 255, 255))
    video = morph_mod.generate_reel_morph(
        raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
        output_path=str(tmp_path / "white.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        logo_path=LOGO)

    frames = legibility.sample_frames(video, SAMPLES)
    failures = legibility.illegible(frames, text_regions.morph_regions(
        morph_mod.print_rect(PHOTO_SIZE)[3], LOGO))

    assert any("masthead" in f for f in failures), failures


@needs_ffmpeg
def test_a_file_with_no_duration_is_an_error_rather_than_zero_frames(tmp_path):
    empty = tmp_path / "not-a-video.mp4"
    empty.write_bytes(b"")

    with pytest.raises(RuntimeError):
        legibility.sample_frames(empty, 2)
