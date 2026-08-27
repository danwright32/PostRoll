"""No photograph in the Thursday scroll reel is painted over by the chrome (#898).

Reported from a published reel: the reel opened on two landscape prints sliced
through the middle by the cream title band, and neither was ever seen whole at
any point in the file.

The band used to be laid ON the photography (#752): the strip was cropped to
the full frame and the band painted over the top of that crop. Measured on a
real strip of twelve 3:2 photographs, row one spanned y=64 to y=386 against a
band covering 170 to 390, so 106px of it survived and every one of those pixels
sat inside `SAFE_TOP`, which is what the phone's status bar and Dynamic Island
cover. The strip only scrolls upward, so row one never descended into clear
space.

Dan, 2026-08-27: the header stays where it is and photographs must never be
obscured by it, at any point in the scroll.

## How it measures

Where the prints LAND, not where they can still be seen. The band and the
footer mask are both opaque cream, so a frame read after the chrome is drawn
reports the same thing whether the chrome is covering a photograph or the mat:
the first version of this file asked the question that way and its footer
assertion could not fail (L1, L159). So both readings are taken from
`place_strip`, which is the frame before any chrome, and the question becomes
whether a print is placed where the chrome will stand.

Two frames at each sampled scroll position: one from the real strip, one from a
strip of bare mat the same size. Differencing them leaves exactly the ink the
PHOTOGRAPHY contributed.

Rendering the difference rather than hunting for a known colour is the same
choice `test_phone_safe_area.py` makes and for the same reason: any quantity
computed over a band as a whole counts the cream and the hairlines too (L146).

The viewport reading is the positive control, and it is not decoration. A
difference that reports nothing anywhere would satisfy both band assertions
while measuring a frame with no photographs in it at all, which is precisely
what a broken fixture, a failed strip build or a mis-sized crop produces (L159,
L98). It is asserted at every sample, not once.

## Why it samples the whole scroll

An opening-frame check passes while every later frame still clips: the strip
moves, so the print under the band at t=0 is a different print at t=0.5 (L142,
L101). The samples span the full travel the encoder renders, taken through the
generator's own `max_scroll_for` and `compose_frame` rather than restated here,
so what is measured is what ships (L107).

No font gate: no type is drawn at all in what this reads, so it measures the
same thing whether the macOS faces are present or Pillow's default stands in
for them.
"""

from __future__ import annotations

import pytest
from PIL import Image, ImageChops

from postroll.media.generate_reel_scroll import (
    CANVAS_H,
    CANVAS_W,
    CREAM,
    FOOTER_H,
    TITLE_BAND_BOTTOM,
    build_collage_strip,
    max_scroll_for,
    place_strip,
)

EVENT = "Battery Dance Festival"
ORG = "Battery Dance"
VENUE = "Robert F. Wagner Jr. Park"

#: Where the scroll is read. Eleven positions across the whole travel rather
#: than the ends: a print clipped only in the middle of the file is exactly
#: what an opening frame and a closing frame both miss.
SAMPLES = 11

#: How much photographic ink has to reach the viewport for the difference to be
#: believed. Sized against the smallest thing the reading has to see, which is
#: one print scrolling in at a viewport edge: a row spans the mat's full width,
#: so even a one pixel sliver of one is most of a thousand pixels. A hundred stands well clear of the antialiasing
#: on a hairline and well below anything a real frame carries.
MIN_PHOTO_INK = 100


def _photo_ink(strip: Image.Image, bare: Image.Image, scroll_y: int):
    """The pixels the photographs put on the frame, as a mask."""
    return ImageChops.difference(place_strip(strip, scroll_y),
                                 place_strip(bare, scroll_y)).convert("L")


def _ink_in(mask: Image.Image, top: int, bottom: int) -> int:
    band = mask.crop((0, top, CANVAS_W, bottom))
    return sum(1 for value in band.getdata() if value > 0)


@pytest.fixture(scope="module")
def scrolling_strip(tmp_path_factory) -> Image.Image:
    """A strip taller than the frame, from the shape that reported this.

    3:2 landscape throughout, which is what Dan shoots and what the reported
    reel had: it is the shape where none of row one survived the band at all,
    against 158px for a square and 400px for an upright.
    """
    from reel_render_fixtures import SCROLLING_PHOTOS, structured_photo

    tmp = tmp_path_factory.mktemp("scroll_viewport")
    paths = [structured_photo(tmp / f"p{seed}.jpg", seed)
             for seed in range(SCROLLING_PHOTOS)]
    return build_collage_strip(paths, seed=163)


def test_the_strip_is_taller_than_the_frame(scrolling_strip):
    """Otherwise there is no scroll and every reading below is of a still."""
    assert max_scroll_for(scrolling_strip.height) > 0, (
        f"the strip is {scrolling_strip.height}px against a {CANVAS_H}px frame, "
        "so nothing scrolls and the samples below all read the same picture"
    )


def test_no_photograph_is_drawn_under_the_title_band(scrolling_strip):
    bare = Image.new("RGB", scrolling_strip.size, CREAM)
    travel = max_scroll_for(scrolling_strip.height)

    for i in range(SAMPLES):
        scroll_y = round(travel * i / (SAMPLES - 1))
        mask = _photo_ink(scrolling_strip, bare, scroll_y)

        seen = _ink_in(mask, TITLE_BAND_BOTTOM, CANVAS_H - FOOTER_H)
        assert seen >= MIN_PHOTO_INK, (
            f"at scroll {scroll_y} the difference finds only {seen} "
            "photographic pixels in the whole gallery, so the readings below "
            "are measuring a frame with no photography in it"
        )

        under_band = _ink_in(mask, 0, TITLE_BAND_BOTTOM)
        assert under_band == 0, (
            f"at scroll {scroll_y}, {under_band} pixels of photograph are drawn "
            f"above y={TITLE_BAND_BOTTOM}, so the title band is standing on a "
            "print rather than on the mat"
        )


def test_no_photograph_is_drawn_under_the_footer(scrolling_strip):
    bare = Image.new("RGB", scrolling_strip.size, CREAM)
    travel = max_scroll_for(scrolling_strip.height)
    footer_top = CANVAS_H - FOOTER_H

    for i in range(SAMPLES):
        scroll_y = round(travel * i / (SAMPLES - 1))
        mask = _photo_ink(scrolling_strip, bare, scroll_y)

        under_footer = _ink_in(mask, footer_top, CANVAS_H)
        assert under_footer == 0, (
            f"at scroll {scroll_y}, {under_footer} pixels of photograph are "
            f"drawn below y={footer_top}, so the footer mask is covering a "
            "print rather than closing the gallery"
        )
