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


def _render(layout, strip_band=None):
    canvas = Image.new("RGB", (gc.CANVAS_W, gc.CANVAS_H), (250, 248, 244))
    return gc.render_cell_layout_override(canvas, layout, {}, strip_band=strip_band)


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


def test_a_layout_that_grew_over_the_strip_is_refused(photos):
    """#970, and the shape #965 reported.

    The top row is dragged down until it swallows the branded centre strip. The
    inferred band moves down with it, which is why this used to render happily:
    a `covers_strip` verdict computed from the cells being judged could only
    confirm that the inference agreed with itself (L70).

    So the band is passed IN, recovered from the layout the collage was BUILT
    on rather than from the one being judged.
    """
    over_the_strip = _layout(photos, [(0, 0, 1080, 600),
                                      (0, 690, 536, 100), (544, 690, 536, 100)])

    # The inference still puts it at 600, which is the whole problem: told
    # nothing, the renderer sees a perfectly ordinary layout.
    assert _render(over_the_strip) == 600

    with pytest.raises(ValueError, match="covers_strip"):
        _render(over_the_strip, strip_band=(400, gc.STRIP_H))


def test_the_band_it_was_built_with_does_not_refuse_an_honest_layout(photos):
    """The positive half. A band passed in is only worth having if a layout
    that respects it still renders, or this would refuse every override (L159)."""
    honest = _layout(photos, [(0, 0, 1080, 400),
                              (0, 490, 536, 300), (544, 490, 536, 300)])

    assert _render(honest, strip_band=(400, gc.STRIP_H)) == 400


def test_the_planned_band_comes_from_the_layout_the_collage_was_built_on(photos):
    """Where the band comes from, and that it does not move with the override.

    `plan_base_layout` replays the arrangement a seed produces, so the answer
    depends on the photographs and the seed and on nothing the person has since
    dragged. Two different overrides of the same day get the same band.
    """
    ratios = [1.5] * len(photos)
    _, _, _, planned = gc.plan_base_layout(ratios, seed=7)

    assert planned == gc.plan_base_layout(ratios, seed=7)[3], "not deterministic"
    assert planned > 0

    # And it is genuinely a function of the seed rather than a constant, or the
    # check above would pass against a band that is always the same number.
    bands = {gc.plan_base_layout([1.5] * 7, seed=s)[3] for s in range(12)}
    assert len(bands) > 1, (
        "every seed puts the strip in the same place, so passing the band in "
        "measures nothing the inference did not already know")


def test_a_render_through_generate_collage_carries_the_band(photos, tmp_path):
    """Built is not wired (L3).

    The predicate is worth nothing while `generate_collage` still passes None,
    which is what it did until #970. Driven through the real entry point with a
    real override, so the wiring is what fails if it is undone.
    """
    ratios = [1.5] * len(photos)
    _, _, planned, strip_y = gc.plan_base_layout(ratios, seed=7)

    swallowing = [
        {"photo_path": photos[0], "x": 0, "y": 0, "w": 1080, "h": strip_y + gc.STRIP_H},
        {"photo_path": photos[1], "x": 0, "y": strip_y + gc.STRIP_H + 16, "w": 536, "h": 200},
        {"photo_path": photos[2], "x": 544, "y": strip_y + gc.STRIP_H + 16, "w": 536, "h": 200},
    ]

    with pytest.raises(ValueError, match="covers_strip"):
        gc.generate_collage(photos, str(tmp_path / "c.png"), seed=7,
                            cell_layout=swallowing, write_layout_sidecar=False)
