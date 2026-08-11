"""Where the Tuesday reel hangs its print, asked rather than left behind (#323, #322).

Two defects in one place.

`_PRINT_H` was a module global that `prepare_photo` overwrote on every call
(#323). The renderer read it to place the caption and clip the divider, and the
tests read it back off the module to work out where the caption should be. So
the expected position and the drawn position came from one value: a wrong print
height moved both together and every check passed, most confidently at the
moment the layout was broken (L70). It also meant the morph, which prepares two
photos, kept only the SECOND photo's height, so a RAW and an edit of different
shapes placed the caption under the wrong one.

And the height was unbounded (#322). A 2:3 portrait produced a 1404px print,
putting the caption at y=1920, past the colophon rule at 1706 and off the bottom
of the canvas. Nothing refused it; the reel rendered broken and reported success.

`print_rect` answers both: a pure function of the photo's size, clamped to the
space actually available, that the renderer, the legibility bands and these
tests all call from the same declared input rather than one reading a side
effect of another.
"""

from __future__ import annotations

import pytest

from postroll.media import generate_reel_morph as morph


def rect(width: int, height: int):
    return morph.print_rect((width, height))


# ── it is a function of its input, not of what ran last ──────────────────────


def test_the_same_photo_size_always_gives_the_same_rectangle():
    assert rect(3000, 2000) == rect(3000, 2000)


def test_asking_about_one_photo_does_not_change_the_answer_for_another():
    # The whole defect: preparing a second photo used to overwrite the first
    # photo's height, and whatever ran last decided where the caption went.
    landscape = rect(3000, 2000)
    _ = rect(2000, 3000)

    assert rect(3000, 2000) == landscape


def test_a_landscape_photo_fills_the_plate_width():
    left, top, width, height = rect(3000, 2000)

    assert width == morph.PRINT_W
    assert left == (morph.CANVAS_W - morph.PRINT_W) // 2
    assert top == morph.PRINT_Y
    assert height == int(morph.PRINT_W / 1.5)


def test_the_rectangle_keeps_the_photo_s_shape():
    for w, h in [(3000, 2000), (2000, 2000), (2000, 2500), (2000, 3000)]:
        _, _, width, height = rect(w, h)
        assert width / height == pytest.approx(w / h, rel=0.01), (w, h)


# ── a tall photo cannot push the caption off the plate ───────────────────────


def caption_bottom(height: int) -> int:
    """Where the caption block under a print of `height` ends.

    Built from the renderer's own offsets rather than a number copied here, so
    moving the caption moves this with it.
    """
    return morph.PRINT_Y + height + morph.PLACARD_TOP_GAP + morph.PLACARD_BLOCK_H


@pytest.mark.parametrize("w,h,name", [
    (3000, 2000, "3:2 landscape"),
    (2000, 2000, "square"),
    (2000, 2500, "4:5 portrait"),
    (2000, 3000, "2:3 portrait"),
    (1000, 3000, "extreme portrait"),
])
def test_the_caption_stays_clear_of_the_colophon_rule(w, h, name):
    _, _, _, height = rect(w, h)

    assert caption_bottom(height) <= morph.FOOTER_RULE_Y, (
        f"a {name} photo puts the caption at {caption_bottom(height)}, past the "
        f"colophon rule at {morph.FOOTER_RULE_Y}")


@pytest.mark.parametrize("w,h", [(3000, 2000), (2000, 2000), (2000, 3000), (1000, 3000)])
def test_the_print_stays_inside_the_plate(w, h):
    left, top, width, height = rect(w, h)

    assert left >= 0 and left + width <= morph.CANVAS_W, (left, width)
    assert top >= morph.RULE_Y, "the print overlaps the masthead rule"
    assert top + height <= morph.FOOTER_RULE_Y, "the print overlaps the colophon"


def test_a_tall_photo_narrows_rather_than_overflowing():
    # The clamp takes width down from the height cap and re-centres, instead of
    # cropping the photograph to a shape Dan did not choose.
    left, _, width, height = rect(2000, 3000)

    assert height == morph.MAX_PRINT_H
    assert width < morph.PRINT_W
    assert left == (morph.CANVAS_W - width) // 2, "a narrowed print must re-centre"


# ── the renderer and the bands agree because they ask the same question ──────


def test_the_renderer_hangs_the_print_where_print_rect_says():
    from PIL import Image

    photo = Image.new("RGB", (3000, 2000), (120, 90, 70))
    canvas = morph.prepare_photo(photo, photo)
    left, top, width, height = rect(3000, 2000)

    # Resolved by an independent route: the rectangle says where the photograph
    # is, and the pixels are read from the rendered canvas to confirm it is
    # actually there (L70).
    #
    # Asked as "mat or photograph" rather than "exactly cream", because the
    # print's drop shadow is blurred by 14px and tints the mat just outside the
    # rectangle. An exact-cream assertion would fail on a correct render, which
    # is a guard nobody would keep.
    def is_mat(xy) -> bool:
        return min(canvas.getpixel(xy)) > 200

    x = left + width // 2
    assert not is_mat((x, top + height // 2)), (
        "the middle of the print rectangle is mat, so the photograph is elsewhere")
    assert is_mat((x, top - 60)), "there is photograph above where the print starts"
    assert is_mat((x, top + height + 60)), "there is photograph below where it ends"
