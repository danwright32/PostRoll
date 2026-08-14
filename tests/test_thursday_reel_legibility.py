"""The Thursday scrolling reel, read back out of the encoded file.

Split out of test_frame_legibility.py by #512. That file was 580s of the 846s
its four siblings summed to, so it was a shard on its own and nothing could
divide it further while it was one file: its shard's pytest step ran 3m42s
against the other's 2m58s, and the merge wait was the slower of the two.

The line is the one the file already drew in its own section headings. The
Tuesday reel checks (morph and slider) stayed; the scrolling reel's checks came
here. They share only the photographs, the silent track and the closing
graphic, which now live in `reel_render_fixtures.py` rather than being copied.

Every check here renders a real reel and reads pixels back, which is where the
suite's time goes. `make test-python-fast` deselects it; CI and
`make test-python` still run it (#413).
"""

from __future__ import annotations

import pytest
from PIL import Image

from conftest import needs_ffmpeg, needs_mac_fonts
from postroll.media import frame_legibility as legibility
from postroll.media import generate_reel_morph as morph_mod
from postroll.media import generate_reel_scroll as scroll_mod
from postroll.media import program_plate as plate_mod
from postroll.media import text_regions
from reel_render_fixtures import LOGO, PHOTO_SIZE, SAMPLES

pytestmark = pytest.mark.slow

def assert_the_strip_really_scrolls(photo_paths, seed):
    """The fixture must build a strip taller than the canvas.

    Below that the generator prints "strip shorter than canvas, scroll
    collapsed to a hold", pads the strip and renders a still. Every Thursday
    reel test used to run in that state, so nothing about the scroll was ever
    checked and the tests read as though it was (#319, L101).

    Asserted from the strip rather than from the photo count, because the count
    at which a strip clears the canvas moves with the row rhythm, the gaps and
    the colophon. A number pinned here would silently stop meaning what it says.
    """
    strip = scroll_mod.build_collage_strip(list(photo_paths), seed=seed, logo_path=LOGO)
    assert strip.height > scroll_mod.CANVAS_H, (
        f"this fixture builds a {strip.width}x{strip.height} strip against a "
        f"{scroll_mod.CANVAS_W}x{scroll_mod.CANVAS_H} canvas, so the generator "
        "collapses the scroll to a static hold and the reel never moves. "
        "Whatever this test believes it is checking about a scrolling reel, it "
        "is not.")


@needs_ffmpeg
@needs_mac_fonts
def test_the_thursday_reel_header_reads_all_the_way_through(
        many_photos, silent_audio, tmp_path):
    # A short scroll rather than the shipping 40 seconds. `scroll_duration` is a
    # real parameter of the generator, not a seam opened for the test, and the
    # header chrome under test does not change with the duration.
    #
    # The header is pinned to the frame, so it does not move with the strip, but
    # the reel still has to be a scrolling one: a still cannot show a header
    # sitting over photographs passing beneath it.
    assert_the_strip_really_scrolls(many_photos, seed=298)

    video = scroll_mod.generate_reel_scroll(
        photo_paths=many_photos, audio_path=silent_audio,
        output_path=str(tmp_path / "scroll.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        seed=298, scroll_duration=4.0, logo_path=LOGO)

    frames = legibility.sample_frames(video, SAMPLES)

    assert legibility.illegible(frames, text_regions.scroll_regions()) == []


@needs_ffmpeg
@needs_mac_fonts
def test_the_thursday_reel_colophon_reads_wherever_it_scrolls_to(
        many_photos, silent_audio, tmp_path):
    """#306: the mark is found in each frame rather than declared.

    `tests/test_gallery_alignment.py` checks the colophon in the STRIP, before
    any of it is animated or encoded. This is the same element read back out of
    the file that gets uploaded, which is where the pixel format, the colour
    range and the compression have had their say.

    Also asserts the sample really did straddle the mark going off screen. Any
    band the search could match on every single frame would be something other
    than a colophon travelling with the strip, and the check would be following
    the wrong thing while reporting a clean reading.
    """
    assert_the_strip_really_scrolls(many_photos, seed=306)

    video = scroll_mod.generate_reel_scroll(
        photo_paths=many_photos, audio_path=silent_audio,
        output_path=str(tmp_path / "scroll-colophon.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        seed=306, scroll_duration=4.0, logo_path=LOGO)

    frames = legibility.sample_frames(video, SAMPLES)
    regions = text_regions.scroll_moving_regions(LOGO)
    assert regions, "the colophon has to be checked, not skipped"

    assert legibility.illegible_moving(frames, regions) == []

    bands = [legibility.find_ink_band(frame, regions[0]) for frame in frames]
    assert any(b is not None for b in bands), "the render never showed the mark"
    assert any(b is None for b in bands), (
        "the mark was found on every frame of a scrolling strip, so the search "
        "is matching something that does not travel with it")


@needs_ffmpeg
@needs_mac_fonts
def test_a_white_wordmark_on_the_cream_mat_fails_the_thursday_colophon(
        many_photos, silent_audio, tmp_path):
    """The guard seen refusing on a real encoded render (LESSONS.md L1).

    The wrong mark file, which is the defect that has shipped on this element
    more than once: white ink on the cream mat, invisible, with the render
    otherwise completely normal.
    """
    white = tmp_path / "logo-white.png"
    with Image.open(LOGO) as source:
        rgba = source.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            pixels[x, y] = (255, 255, 255, pixels[x, y][3])
    rgba.save(white)

    video = scroll_mod.generate_reel_scroll(
        photo_paths=many_photos, audio_path=silent_audio,
        output_path=str(tmp_path / "scroll-white.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        seed=306, scroll_duration=4.0, logo_path=str(white))

    frames = legibility.sample_frames(video, SAMPLES)
    failures = legibility.illegible_moving(
        frames, text_regions.scroll_moving_regions(str(white)))

    assert any("colophon" in f for f in failures), failures
