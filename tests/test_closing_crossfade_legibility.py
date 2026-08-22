"""#335: the 1.5 seconds a Tuesday reel spends dissolving into its closing graphic.

Split out of `test_frame_legibility.py` for #810, the way #512 split the
scrolling reel's checks out of the same file. That file was the whole of the
`legibility` shard and 33.7% of the measured suite, so it set the floor on what
any arrangement of the three-way matrix in `.github/workflows/swift.yml` could
achieve: a file cannot be divided across runners, so no split could beat it.
These six checks are about two thirds of that file, and they are a coherent two
thirds, which is why they are the cut.

What they cover, unchanged from where they came from. Every Tuesday reel ends by
dissolving into the before/after graphic and holding on it. The reel's frames
were checked and the graphic was checked as a still, and nothing measured the
1.5 seconds between them, which is the one window a still cannot show and the
premise the whole frame-checking system was built on (#298).

It is not a dissolve between two similar frames: the plate holds ONE print and
the graphic holds three, and the caption moves from left-aligned below the print
to centred above each strip, so two differently-placed captions are on screen at
once at partial opacity.

The measurement itself, the template registry and the reel body's own read stay
in `test_frame_legibility.py`.
"""

from __future__ import annotations

import pytest
from PIL import Image

from conftest import needs_ffmpeg, needs_mac_fonts
from postroll.media import frame_legibility as legibility
from postroll.media import generate_reel_morph as morph_mod
from postroll.media import generate_reel_slider as slider_mod
from postroll.media import text_regions
from reel_render_fixtures import LOGO, PHOTO_SIZE

# Renders a real reel per check and reads the encoded file back, which is where
# the time goes. `make test-python-fast` deselects it; CI and `make test-python`
# still run it (#413).
pytestmark = pytest.mark.slow


#: How many moments of the 1.5s dissolve are read. Five puts a frame at each
#: end, at the midpoint and either side of it, which is where both designs are
#: at their weakest.
CROSSFADE_SAMPLES = 5

#: Frames of the same design differ by only a few units after the encode, and
#: the plate and the graphic differ by around sixty. Measured, not guessed: the
#: closing hold reads 3.5 against the graphic handed in and 59.6 against the
#: reel's own last plate frame, so anything under this is the same picture and
#: the two cases are nowhere near the boundary.
SAME_PICTURE = 15.0


def _reel_and_regions(which, photos, silent_audio, closing_graphic, tmp_path):
    """One rendered reel with its closing graphic, and the bands it draws."""
    if which == "morph":
        video = morph_mod.generate_reel_morph(
            raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
            output_path=str(tmp_path / "morph_closing.mp4"),
            event_name="Reference Event", org="Reference Org",
            venue="Reference Venue",
            closing_frame_path=closing_graphic, logo_path=LOGO)
        return (morph_mod, video,
                text_regions.morph_regions(morph_mod.print_rect(PHOTO_SIZE)[3], LOGO))

    video = slider_mod.generate_reel_slider(
        raw_path=photos[0], edit_path=photos[1], bw_path=photos[2],
        audio_path=silent_audio,
        output_path=str(tmp_path / "slider_closing.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        closing_frame_path=closing_graphic, logo_path=LOGO)
    return (slider_mod, video,
            text_regions.slider_regions(LOGO, slider_mod.print_rect(PHOTO_SIZE)[3]))


@needs_ffmpeg
@needs_mac_fonts
@pytest.mark.parametrize("which", ["morph", "slider"])
def test_the_declared_crossfade_window_is_where_the_reel_really_dissolves(
        which, photos, silent_audio, closing_graphic, tmp_path):
    """The window is checked against the RENDER, not against the constants.

    `CLOSING_CROSSFADE_START` and the frame loop are two readings of the same
    numbers, so comparing them would only prove the module agrees with itself
    (L70). What settles it is the encoded file: just before the declared start
    the picture is still the plate, and just after the declared end it is the
    graphic.
    """
    module, video, _ = _reel_and_regions(
        which, photos, silent_audio, closing_graphic, tmp_path)
    graphic = Image.open(closing_graphic).convert("RGB")
    start = module.CLOSING_CROSSFADE_START
    end = start + module.TRANSITION_DURATION

    before = legibility.sample_frames_between(video, start - 0.4, start - 0.1, 2)[0]
    after = legibility.sample_frames_between(video, end + 0.1, end + 0.4, 2)[0]

    assert legibility.mean_difference(before, graphic) > SAME_PICTURE, (
        f"the {which} reel is already showing the closing graphic at "
        f"{start - 0.4:.2f}s, before its declared crossfade start of {start}s")
    assert legibility.mean_difference(after, graphic) < SAME_PICTURE, (
        f"the {which} reel is still not showing the closing graphic at "
        f"{end + 0.4:.2f}s, after its declared crossfade end of {end}s")


@needs_ffmpeg
@needs_mac_fonts
@pytest.mark.parametrize("which", ["morph", "slider"])
def test_something_is_readable_at_every_moment_of_the_closing_crossfade(
        which, photos, silent_audio, closing_graphic, tmp_path):
    """The honest question for a dissolve is whether anything can be read.

    Contrast is the wrong bar mid-dissolve: only pixels at the declared ink
    colour are counted as ink, and a half-faded glyph is not that colour, so the
    ratio reported is whatever the fully-opaque remainder reads at and it cannot
    move. What CAN go wrong here, and what nothing was watching, is the window
    passing through a moment with no legible text on screen at all: the reel
    fading out through empty before the graphic arrives.

    Measured on this render, the masthead band never drops below about 1500 ink
    pixels across the window, while the colophon carries none for roughly the
    middle 0.6 seconds. Two marks of different sizes at different heights cannot
    both be at full strength mid-dissolve, so the mark is expected to go quiet;
    the whole design going quiet is not.
    """
    module, video, regions = _reel_and_regions(
        which, photos, silent_audio, closing_graphic, tmp_path)
    start = module.CLOSING_CROSSFADE_START
    frames = legibility.sample_frames_between(
        video, start, start + module.TRANSITION_DURATION, CROSSFADE_SAMPLES)

    blank = []
    for index, frame in enumerate(frames):
        readable = [region.name for region in regions
                    if legibility.read_region(frame, region).has_ink]
        if not readable:
            blank.append(index)

    assert not blank, (
        f"the {which} reel's crossfade has nothing of any declared ink on "
        f"screen at sample(s) {blank} of {CROSSFADE_SAMPLES} across "
        f"{start}s to {start + module.TRANSITION_DURATION}s, so the dissolve "
        f"passes through a moment with no readable text at all")

    # Both ENDS of the dissolve are moments a design is at full strength, so
    # they are the ones that can be held to a bar. They are held to DIFFERENT
    # bars, because they are different designs (#777).
    #
    # The start is the reel's own last plate, so the reel's declared bands are
    # the right question. The end is the before/after graphic, and asking the
    # REEL's bands about it measures one template against another's
    # expectations: it passed only because the two happened to put plain mat at
    # the same coordinates, and #753 moving the before/after colophon is what
    # showed that up. The honest claim about that moment is that the dissolve
    # has arrived at the graphic it was given, which is what is asserted here;
    # whether that graphic reads is the before/after's own business, held by
    # tests/test_gallery_alignment.py and the goldens.
    assert legibility.illegible([frames[0]], regions) == []

    graphic = Image.open(closing_graphic).convert("RGB")
    arrived = legibility.mean_difference(frames[-1], graphic)
    assert arrived < SAME_PICTURE, (
        f"the {which} reel's dissolve ends {arrived:.1f} of 255 away from the "
        "closing graphic it was handed, so it is not arriving at it")


@needs_ffmpeg
@needs_mac_fonts
@pytest.mark.parametrize("which", ["morph", "slider"])
def test_the_reel_ends_holding_the_closing_graphic(
        which, photos, silent_audio, closing_graphic, tmp_path):
    """The hold is three seconds of the reel and nothing looked at it.

    A band check cannot answer this on its own: the plate and the graphic both
    draw dark ink on cream near the top of the canvas, so every band reads
    comfortably on either, and a reel that never reached its closing graphic
    would pass all of them.
    """
    module, video, _ = _reel_and_regions(
        which, photos, silent_audio, closing_graphic, tmp_path)
    graphic = Image.open(closing_graphic).convert("RGB")
    hold_start = module.CLOSING_CROSSFADE_START + module.TRANSITION_DURATION

    frames = legibility.sample_frames_between(
        video, hold_start + 0.1, module.TOTAL_DURATION, 3)

    worst = max(legibility.mean_difference(frame, graphic) for frame in frames)
    assert worst < SAME_PICTURE, (
        f"the {which} reel's closing hold differs from the graphic it was "
        f"given by {worst:.1f} of 255, so it is holding on something else")
