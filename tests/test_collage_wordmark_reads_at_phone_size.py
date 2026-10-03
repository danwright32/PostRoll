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
