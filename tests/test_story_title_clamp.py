"""The story's title has a floor under it (#756).

Split out of #752, which fixed the scroll reel and left this deliberately.

`generate_story.draw_title` anchors the title bottom-up off the photograph, so
where it starts depends entirely on where the photograph ends up. With an
UPRIGHT photograph the photo fills its area and sits at `PHOTO_TOP_Y`, so a
single-line title starts around y=148 and a two-line title around y=33, both
inside the band the iPhone status bar and Dynamic Island cover. With a LANDSCAPE
photograph the photo is centred lower and the title clears the band by hundreds
of pixels.

Deferred on Dan's call (2026-08-20): he does not shoot upright photographs for
stories and has never seen it. Filed rather than dropped because the geometry
has no floor, so the first upright photograph, or any change to `PHOTO_TOP_Y`,
brings it straight back.

The fix measures the title before the photograph is placed and starts the photo
below it, and only when the title needs the room. That last part is what these
tests are mostly about: a landscape story has to render exactly as it does
today, or a fix for a case Dan never hits has changed every story he does.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image, ImageChops

from conftest import needs_mac_fonts
from postroll.media import generate_story as story
from postroll.media.design_tokens import SAFE_TOP

pytestmark = pytest.mark.slow

REPO_ROOT = Path(__file__).resolve().parent.parent
LOGO = str(REPO_ROOT / "postroll" / "assets" / "logo-black.png")

#: Long enough to wrap to two lines in the script face, which is the case with
#: the least room: each extra line moves the block another ~72px up (L101).
TWO_LINE = "The One-Man Odyssey and Other Stories"
ONE_LINE = "The One-Man Odyssey"
ORG = "A Presenting Organisation"
VENUE = "A Concert Hall"


def _photo(path: Path, portrait: bool) -> str:
    size = (1332, 2000) if portrait else (2000, 1332)
    Image.new("RGB", size, (128, 128, 128)).save(path, "JPEG", quality=92)
    return str(path)


def _render(tmp_path: Path, name: str, portrait: bool, tag: str) -> Image.Image:
    out = tmp_path / f"story-{tag}.png"
    story.generate_story(photo_path=_photo(tmp_path / f"p-{portrait}.jpg", portrait),
                         event_name=name, org=ORG if name else "",
                         venue=VENUE if name else "",
                         output_path=str(out), logo_path=LOGO)
    return Image.open(out)


def _text_pixels_in_band(named: Image.Image, unnamed: Image.Image) -> int:
    """The same differencing `tests/test_phone_safe_area.py` measures with: two
    renders of one photograph, one carrying the words and one not, so whatever
    changed inside the top band is text this template put there (L146)."""
    a = named.convert("RGB").crop((0, 0, named.width, SAFE_TOP))
    b = unnamed.convert("RGB").crop((0, 0, unnamed.width, SAFE_TOP))
    return sum(1 for pixel in ImageChops.difference(a, b).getdata() if max(pixel) > 12)


# ── The defect ───────────────────────────────────────────────────────────────

@needs_mac_fonts
@pytest.mark.parametrize("name,tag", [(TWO_LINE, "two"), (ONE_LINE, "one")])
def test_an_upright_photograph_keeps_the_title_out_of_the_covered_band(
        name, tag, tmp_path):
    marked = _text_pixels_in_band(_render(tmp_path, name, True, f"{tag}-named"),
                                 _render(tmp_path, "", True, f"{tag}-blank"))

    assert marked == 0, (
        f"a {tag}-line title over an upright photograph draws {marked} pixels "
        f"inside the top {SAFE_TOP}px, which is the band the iPhone status bar "
        "and Dynamic Island cover. Whatever is there is printed under the clock "
        "and the battery and nobody can read it (#756).")


# ── What it may not change ───────────────────────────────────────────────────

@needs_mac_fonts
@pytest.mark.parametrize("name,tag", [(TWO_LINE, "two"), (ONE_LINE, "one")])
def test_a_landscape_story_is_untouched(name, tag, tmp_path):
    """The case Dan actually shoots, held to the pixel.

    A landscape photograph is centred low enough that the title clears the band
    by hundreds of pixels, so the clamp has nothing to do and must do nothing. A
    fix for a case he never hits that moved every story he does would be worse
    than the defect.
    """
    photo = Image.open(_photo(tmp_path / "landscape.jpg", portrait=False))
    canvas = story.create_blurred_background(photo)

    _, clamped = story.place_photo(canvas, photo,
                                   min_top_y=story.required_photo_top(canvas, name))
    _, unclamped = story.place_photo(canvas, photo)

    assert clamped == unclamped, (
        f"the clamp moved a landscape story's photograph from {unclamped} to "
        f"{clamped}. It has hundreds of pixels of clearance already, so the "
        "clamp must be inert here.")


@needs_mac_fonts
def test_an_upright_photograph_is_the_case_that_moves(tmp_path):
    """The positive control for the test above.

    "The clamp changed nothing" is also what a clamp that does nothing at all
    reports, so this proves it moves the photograph in the case it exists for,
    in the same fixture and through the same call (L159).
    """
    photo = Image.open(_photo(tmp_path / "upright.jpg", portrait=True))
    canvas = story.create_blurred_background(photo)

    _, clamped = story.place_photo(canvas, photo,
                                   min_top_y=story.required_photo_top(canvas, TWO_LINE))
    _, unclamped = story.place_photo(canvas, photo)

    assert clamped > unclamped, (
        "the clamp left an upright photograph where it was, so it is not "
        "making room for anything and the check above proves nothing")


@needs_mac_fonts
def test_the_clamp_takes_only_the_room_the_title_needs(tmp_path):
    """The clamp makes room; it does not shove the print down the canvas.

    Every pixel it takes comes out of the photograph, which is the picture the
    post exists for, so this holds it to the minimum: the title's topmost INK
    lands on SAFE_TOP, not somewhere comfortably below it. A clamp with slack
    in it would pass the band check while quietly costing the photograph a
    hundred pixels nobody asked for.
    """
    photo = Image.open(_photo(tmp_path / "upright.jpg", portrait=True))
    canvas = story.create_blurred_background(photo)
    lines, font, _, text_h_single, line_gap = story.title_block(canvas, TWO_LINE)

    _, photo_top = story.place_photo(
        canvas, photo, min_top_y=story.required_photo_top(canvas, TWO_LINE))
    first_line_y = (photo_top - story.GAP_TO_PHOTO - text_h_single
                    - (len(lines) - 1) * line_gap)
    ink_top = first_line_y + story._title_ink_offset(canvas, TWO_LINE)

    assert ink_top == SAFE_TOP, (
        f"the title's topmost ink lands at {ink_top} against a floor of "
        f"{SAFE_TOP}. Above it is unreadable; below it is photograph given "
        "away for nothing.")


@needs_mac_fonts
def test_the_title_lands_between_the_floor_and_the_print(tmp_path):
    """The shape of the template, measured on the rendered pixels.

    A clamp applied to the TITLE rather than to the photograph would pass the
    band check and leave the words floating in the blurred background with the
    print far below. So the title's ink is found on the page and held to both
    ends at once: nothing above SAFE_TOP, and nothing below the top edge of the
    print.

    Both renders are built from ONE placement, so the only difference between
    them is the title. Rendering the nameless one through `generate_story`
    would place its photograph somewhere else, and the difference would then be
    mostly photograph (L146).
    """
    photo = Image.open(_photo(tmp_path / "upright.jpg", portrait=True))
    background = story.create_blurred_background(photo)
    placed, photo_top = story.place_photo(
        background, photo, min_top_y=story.required_photo_top(background, TWO_LINE))

    with_title = story.draw_title(placed.copy(), TWO_LINE, photo_top_y=photo_top)
    without = placed.convert("RGBA")

    difference = ImageChops.difference(with_title.convert("RGB"),
                                       without.convert("RGB"))
    rows = [y for y in range(with_title.height)
            if any(max(difference.getpixel((x, y))) > 12
                   for x in range(0, with_title.width, 4))]

    assert rows, "the title drew nothing at all, so neither bound below means anything"
    assert min(rows) >= SAFE_TOP, (
        f"the title's topmost ink is at {min(rows)}, inside the {SAFE_TOP}px "
        "band the phone covers")
    assert max(rows) <= photo_top, (
        f"the title's lowest ink is at {max(rows)}, below the top of the "
        f"photograph at {photo_top}, so it is printed over the picture")


@needs_mac_fonts
def test_the_measurement_can_still_see_a_title_in_the_band(tmp_path):
    """The control. A difference that had stopped seeing anything would report
    every story clean, which is the shape a green sweep hides (L1, L98)."""
    from PIL import ImageDraw

    plain = Image.new("RGB", (1080, 1920), (128, 128, 128))
    marked = plain.copy()
    ImageDraw.Draw(marked).text((100, 40), "UNDER THE NOTCH", fill=(20, 20, 20))

    assert _text_pixels_in_band(marked, plain) > 0
