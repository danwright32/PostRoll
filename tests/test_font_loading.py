"""One font loader, and it decides how text is shaped (#656).

Six generators each carried their own identical `load_font`, and each one called
`ImageFont.truetype` without naming a layout engine. Pillow then picks the
advanced shaper (raqm) whenever it can find it, so WHICH RENDERER DRAWS DAN'S
TYPE was decided by whatever happened to be installed on the machine doing the
drawing.

That is not hypothetical. Measured on 2026-08-17:

    this Mac, Python 3.9 venv    raqm absent   layout engine BASIC
    this Mac, Python 3.11 venv   raqm present  layout engine RAQM
    CI, Python 3.11              raqm absent   layout engine BASIC

Same Pillow version, same wheel name, different result, and the two renderings
are not the same: the before/after graphic's title band sits about four pixels
across from where it does under the other. The reference frames were the only
thing that would ever have noticed.

So the engine is named explicitly, in one place every generator shares. BASIC is
chosen because it is what CI, the committed reference frames and the shipping
app already produce, so pinning it changes nothing about what Dan gets today and
takes the installed-package lottery out of it. Switching to raqm later is then a
deliberate design change with a reference re-record attached, rather than
something that happens to somebody because they rebuilt a virtualenv.
"""

from __future__ import annotations

import importlib

import pytest
from PIL import ImageFont

from postroll.media import design_tokens as tokens


GENERATORS = [
    "generate_before_after",
    "generate_collage",
    "generate_reel_screen",
    "generate_reel_scroll",
    "generate_story",
    "program_plate",
]


def test_the_shared_loader_pins_the_layout_engine():
    """Whatever is installed, the engine is the one we chose."""
    font = tokens.load_font(tokens.FONT_DETAIL, 40)
    assert font.layout_engine == ImageFont.Layout.BASIC


def test_the_pin_holds_even_when_the_advanced_shaper_is_available():
    """The point of naming it. On a machine where raqm is present, the default
    would silently be the other engine, and nothing in the product would say so.
    """
    if not ImageFont.core.HAVE_RAQM:
        pytest.skip("raqm is not installed here, so there is nothing to override")
    font = tokens.load_font(tokens.FONT_DETAIL, 40)
    assert font.layout_engine == ImageFont.Layout.BASIC


@pytest.mark.parametrize("name", GENERATORS)
def test_every_generator_uses_the_shared_loader(name):
    """Identity, not a source-text match: a copy that merely looks the same is
    a second implementation, and the next change lands in only one of them.
    """
    module = importlib.import_module(f"postroll.media.{name}")
    assert module.load_font is tokens.load_font, (
        f"{name} has its own load_font, so its text is shaped by whatever "
        "Pillow picks rather than by the engine this project chose"
    )


def test_a_font_that_cannot_be_read_still_falls_back():
    """Preserved from the loaders this replaces: a missing font degrades to
    Pillow's default rather than taking the whole render down."""
    font = tokens.load_font("/nope/not-a-font.ttc", 40)
    assert font is not None
