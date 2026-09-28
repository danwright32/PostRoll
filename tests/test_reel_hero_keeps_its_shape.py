"""A landscape photograph with a row of the Thursday reel to itself is shown whole.

Single photo rows were capped at `HERO_MAX_H` (480px) for a landscape, so a 3:2
print filling the 1000px row, which wants about 667px, lost a third of its
height off the top and bottom. Dan, 2026-09-28, on the Broadway Undressed reel:
"the photos that take up their entire row ... are cropped in from the
top/bottom. those should maintain their original aspect ratio".

Landscapes only, by his choice the same day: a portrait at full width would be
taller than the gallery window, so portrait heroes keep their cap and crop.
"""

from __future__ import annotations

import pytest
from PIL import Image

from postroll.media.generate_reel_scroll import (
    CANVAS_W,
    HERO_MAX_H_PORTRAIT,
    ROW_SIZES,
    SIDE_MARGIN,
    build_collage_strip,
)

#: Where the pattern's first single photo row falls: every photo in the rows
#: before it. Derived from the pattern rather than written as 18, so a change
#: to the pattern moves the case with it instead of testing a pair row.
HERO_INDEX = sum(ROW_SIZES[:ROW_SIZES.index(1)])


def _photos(tmp_path, hero_size: tuple[int, int]) -> list[str]:
    """Small files: the layout reads only each photo's SHAPE, and every
    photograph is resized to its cell anyway, so a tenth of the pixels asks
    the same question for a fraction of the decode."""
    paths = []
    for n in range(HERO_INDEX + 1):
        size = hero_size if n == HERO_INDEX else (150, 100)
        path = tmp_path / f"p{n}.jpg"
        Image.new("RGB", size, (40 + n * 7 % 200, 90, 120)).save(path, "JPEG")
        paths.append(str(path))
    return paths


def _hero_cell(tmp_path, hero_size):
    photos = _photos(tmp_path, hero_size)
    _, cells = build_collage_strip(photos, seed=163, return_layout=True,
                                   logo_path=None)
    cell = cells[HERO_INDEX]
    # The premise: this really is a row of one, the full width of the mat.
    assert cell["w"] == CANVAS_W - 2 * SIDE_MARGIN, cell
    return cell


@pytest.mark.parametrize("size", [(150, 100), (160, 90), (200, 100)])
def test_a_landscape_hero_keeps_its_own_aspect_ratio(tmp_path, size):
    cell = _hero_cell(tmp_path, size)
    want = size[0] / size[1]
    got = cell["w"] / cell["h"]
    # Within the one pixel of rounding a whole number height allows.
    assert abs(cell["h"] - cell["w"] / want) <= 1, (
        f"a {size[0]}x{size[1]} hero is laid out {cell['w']}x{cell['h']} "
        f"({got:.3f} against {want:.3f}), so its top and bottom are cropped")


def test_a_portrait_hero_is_still_capped(tmp_path):
    """The other half, so the case above cannot pass by uncapping every hero
    (L159): a 2:3 portrait at full width would be about 1500px, past the cap."""
    cell = _hero_cell(tmp_path, (100, 150))
    assert cell["h"] == HERO_MAX_H_PORTRAIT
