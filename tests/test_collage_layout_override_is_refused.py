"""The render side of the saved collage layout rule (#967).

The app refuses to SAVE an unrenderable layout now, but a layout stored before
that shipped is still on disk, so the renderer is the other half: it refuses
before a single photo is opened rather than drawing a photograph over the
branded centre strip, off the canvas, or on top of another photograph.

The strip is the design's whole point. `generate_collage.py` says at the top
that it exists to be impossible to crop out when shared, so a photo over it
takes the branding off the post.
"""

from __future__ import annotations

import pytest
from PIL import Image

from postroll.media import generate_collage as gc


@pytest.fixture(scope="module")
def photos(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("collage_override")
    paths = []
    for i in range(3):
        p = tmp / f"p{i}.jpg"
        Image.new("RGB", (1200, 800), (40 + i * 60, 90, 140)).save(p)
        paths.append(str(p))
    return paths


def _layout(photos, cells):
    return [{"photo_path": p, "x": x, "y": y, "w": w, "h": h}
            for p, (x, y, w, h) in zip(photos, cells)]


def _render(layout):
    canvas = Image.new("RGB", (gc.CANVAS_W, gc.CANVAS_H), (250, 248, 244))
    return gc.render_cell_layout_override(canvas, layout, {})


def test_an_ordinary_layout_still_renders(photos):
    """The positive control. Without it every refusal below is satisfied by a
    renderer that refuses everything, which would take the editor away rather
    than fix it (L159)."""
    strip_y = _render(_layout(photos, [(0, 0, 1080, 400),
                                       (0, 490, 536, 300), (544, 490, 536, 300)]))
    assert strip_y == 400, "the strip was inferred somewhere other than the gap"


def test_a_cell_under_the_floor_is_refused(photos):
    with pytest.raises(ValueError, match="under_floor"):
        _render(_layout(photos, [(0, 0, 1080, 400),
                                 (0, 490, 536, 300), (544, 490, 536, 40)]))


def test_a_cell_off_the_canvas_is_refused(photos):
    with pytest.raises(ValueError, match="off_canvas"):
        _render(_layout(photos, [(0, 0, 1080, 400),
                                 (0, 490, 536, 300), (544, 1800, 536, 300)]))


def test_two_cells_over_one_another_are_refused(photos):
    with pytest.raises(ValueError, match="overlapping"):
        _render(_layout(photos, [(0, 0, 1080, 400),
                                 (0, 490, 700, 300), (600, 490, 480, 300)]))


def test_the_refusal_says_what_to_do_about_it(photos):
    """A message naming a code and nothing else leaves the person with a broken
    export and no next step (L111). The way out is regenerating the day."""
    with pytest.raises(ValueError, match="[Rr]egenerate"):
        _render(_layout(photos, [(0, 0, 1080, 400),
                                 (0, 490, 536, 300), (544, 490, 536, 40)]))


def test_the_strip_band_is_not_judged_here_and_the_docstring_says_why(photos):
    """#970 is NOT closed by this file, and the reason is worth pinning.

    Where the strip sits is inferred from the same cells being judged, so a
    `covers_strip` verdict computed here could only confirm the inference
    agrees with itself (L70). Grow a row down over the strip and the inferred
    band moves down with it, which is exactly this layout: it is the shape #965
    reported, and the renderer accepts it because nothing here knows where the
    strip WAS.
    """
    over_the_strip = _layout(photos, [(0, 0, 1080, 600),
                                      (0, 690, 536, 100), (544, 690, 536, 100)])
    assert _render(over_the_strip) == 600, (
        "the inference put the strip somewhere other than the gap this layout "
        "left, which would change what this test is about")
