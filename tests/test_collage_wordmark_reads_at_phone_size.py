"""The collage's signature has to read on a phone, inside the plate it has.

A design round on 2026-10-03, run on Dan's own Broadway Undressed Sunday
collage at phone width, settled the mark at 400 rather than 240. The plate
stays 90px: every saved arrangement leaves exactly that gap between its rows,
so a taller plate would mean redoing every layout Dan has already arranged. It
fits because the wordmark file is mostly padding, and only its ink has to clear
the plate's edges.

Measured as drawn ink on a real render, because the width constant is a box
around that padding and the complaint was about what is visible.
"""

from __future__ import annotations

import json

from PIL import Image, ImageChops

from postroll.media.generate_collage import generate_collage
from postroll.media.layout_sidecar import layout_sidecar_path
from postroll.media.wordmark import BLACK

#: 400 draws about 342px of ink; the 240 this replaced drew about 208.
MIN_INK_W = 320
#: Clear cream between the ink and the plate's top and bottom edges, so the
#: mark never reads as touching the photographs above and below it.
MIN_CLEARANCE = 8


def _plate_ink(tmp_path, photo: str) -> tuple[tuple[int, int, int, int], int, int]:
    out = tmp_path / "collage.png"
    generate_collage([photo] * 4, str(out), "Test Event", "", "Venue",
                     logo_path=BLACK, seed=7)
    strip = json.loads(layout_sidecar_path(out).read_text())["strip"]
    canvas = Image.open(out).convert("RGB")
    # The right half of the plate: the title sits on the left, and its dark
    # brown is above the threshold anyway. The mark is the only black here.
    top, h = strip["y"], strip["h"]
    plate = canvas.crop((canvas.width // 2, top, canvas.width, top + h))
    r, g, b = (ch.point(lambda v: 255 if v < 50 else 0) for ch in plate.split())
    box = ImageChops.multiply(ImageChops.multiply(r, g), b).getbbox()
    assert box, "no wordmark ink found on the collage's caption plate"
    return box, h, canvas.width


def test_the_collage_signs_large_enough_to_read(tmp_path, sample_photo):
    (left, _, right, _), _, width = _plate_ink(tmp_path, sample_photo)
    assert right - left >= MIN_INK_W, (
        f"the collage's wordmark is {right - left}px of ink across a {width}px "
        f"frame, under the {MIN_INK_W} it needs to read on a phone")


def test_the_larger_mark_still_sits_inside_the_plate(tmp_path, sample_photo):
    (_, top, _, bottom), plate_h, _ = _plate_ink(tmp_path, sample_photo)
    assert top >= MIN_CLEARANCE and plate_h - bottom >= MIN_CLEARANCE, (
        f"the wordmark's ink runs from {top} to {bottom} on a {plate_h}px "
        f"plate, leaving under {MIN_CLEARANCE}px of cream at an edge")


# ── long names: the text and the mark share the squeeze ──────────────────────
#
# Measured on 2026-10-03 over the 22 events in Dan's library: at 400 the title
# or detail line ran under the mark on 5 of them, and at the old 240 Quarter
# Time's venue already touched it. Dan's call, from a second round: the detail
# line tightens first (letter spacing to 2, then size to 16), and then the mark
# takes whatever room is left, splitting the squeeze evenly.

from postroll.media import generate_collage as collage  # noqa: E402

#: Real detail lines from the library, the two longest, verbatim.
QUARTER_TIME = ("Quarter Time", "Young New Yorkers' Chorus",
                "The Church of St. Mary the Virgin")
BLUDLINE = ("BLUDLINE: A Hip-Hop Odyssey", "Fermin Suero, Jr. and Pete White",
            "Greenwich House Theater")
#: Longer than anything in the library, so the last resorts are exercised
#: rather than shipping as code nothing has ever run (L101).
ABSURD = ("An Evening of Songs from the Golden Age of the American Musical",
          "The Metropolitan Community Chorus and Friends of the Orchestra",
          "The Cathedral Church of Saint John the Divine, Morningside Heights")


def _plate(event: tuple[str, str, str], logo: str | None) -> Image.Image:
    canvas = Image.new("RGB", (collage.CANVAS_W, collage.STRIP_H + 40),
                       (40, 30, 25))
    return collage.draw_branded_strip(canvas, 20, *event, logo).convert("RGB")


def _ink_columns(plate: Image.Image, threshold: int) -> list[int]:
    """Columns holding any pixel darker than `threshold` in every channel."""
    band = plate.crop((collage.MAT, 20, collage.CANVAS_W - collage.MAT,
                       20 + collage.STRIP_H))
    r, g, b = (ch.point(lambda v: 255 if v < threshold else 0)
               for ch in band.split())
    mask = ImageChops.multiply(ImageChops.multiply(r, g), b)
    return [x for x in range(mask.width)
            if mask.crop((x, 0, x + 1, mask.height)).getbbox()]


def _text_right_and_mark_left(event) -> tuple[int, int]:
    """Right edge of the title and detail, and left edge of the mark's ink.

    Two renders of one plate. The text is measured with no mark drawn, because
    the mark's soft edge is as dark as the text's and would read as text
    touching it. The fit depends only on the text, so both renders lay the text
    out identically.
    """
    mark = _ink_columns(_plate(event, BLACK), 30)
    assert mark, f"no mark drawn on the plate for {event[0]!r}"
    text = _ink_columns(_plate(event, None), 140)
    return (max(text) if text else 0), mark[0]


def test_a_short_name_keeps_the_full_mark_and_the_full_detail_line():
    fit = collage.fit_plate("Broadway Undressed", "54 Below")
    assert (fit.logo_width, fit.detail_size, fit.detail_spacing, fit.title_size) == (
        collage.LOGO_WIDTH, collage.DETAIL_SIZE, collage.DETAIL_SPACING,
        collage.TITLE_SIZE)


def test_the_longest_real_names_split_the_squeeze_evenly():
    for event in (QUARTER_TIME, BLUDLINE):
        fit = collage.fit_plate(event[0], collage.plate_detail_line(*event))
        assert fit.detail_spacing >= collage.DETAIL_SPACING_FLOOR, event[0]
        assert fit.detail_size >= collage.DETAIL_SIZE_FLOOR, event[0]
        assert fit.title_size == collage.TITLE_SIZE, event[0]
        # The mark gave some way, and not all of it.
        assert collage.LOGO_MIN_WIDTH < fit.logo_width <= collage.LOGO_WIDTH, (
            event[0], fit.logo_width)


def test_no_name_runs_under_the_mark():
    for event in (QUARTER_TIME, BLUDLINE, ABSURD, ("Test Event", "", "Venue")):
        text_right, mark_left = _text_right_and_mark_left(event)
        assert mark_left - text_right >= collage.TEXT_TO_MARK_GAP - 2, (
            f"{event[0]!r}: the text ends at x={text_right} and the mark's ink "
            f"starts at x={mark_left}, closer than the "
            f"{collage.TEXT_TO_MARK_GAP}px gap the plate keeps")


def test_the_mark_never_drops_below_its_floor():
    fit = collage.fit_plate(ABSURD[0], collage.plate_detail_line(*ABSURD))
    assert fit.logo_width == collage.LOGO_MIN_WIDTH
    # The detail line is cut short before the title is touched.
    assert fit.detail.endswith("\u2026") and fit.title == ABSURD[0]
