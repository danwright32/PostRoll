"""The program plate: the composition every Tuesday reel is built on (#164).

A printed-program page. Masthead top-left over a rose-gold rule, the photograph
matted and hung as a print, a caption placard below it, and a footer colophon
closing the bottom.

It lived inside `generate_reel_morph` while only one template drew it. #164 is
the bill for that: when the plate became the Tuesday look, the slider, which
renders a Tuesday reel whenever a B&W after is supplied, was not brought across
and kept the pre-redesign flat-cream design. Two renderers each carrying their
own copy of a composition is how one of them gets left behind, so there is one
copy here and both import it.

Nothing in here draws a template of its own, which is why it is not named
`generate_*`: `test_every_renderer_module_is_claimed_by_a_template` walks that
glob and would demand an entry in `TEMPLATE_MODULES` for a module that renders
nothing. It still lands in both reels' fingerprint closures through the import,
so a change to the plate moves both.
"""

from __future__ import annotations

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from .design_tokens import (
    CREAM,
    CREAM_EDGE,
    FONT_DETAIL,
    FONT_DETAIL_BOLD,
    FONT_DETAIL_LIGHT,
    FONT_DETAIL_MEDIUM,
    FONT_SCRIPT,
    MAT_PRINT as MAT,
    ROSE_GOLD,
    TEXT_DARK,
    WARM_MID,
)
from .brand_text import detail_lines
from .generate_before_after import placard_text


CANVAS_W = 1080
CANVAS_H = 1920

PRINT_W = CANVAS_W - 2 * MAT
MASTHEAD_Y = 176               # SignPainter title
VENUE_Y = 285
RULE_Y = 338
PRINT_Y = 430                  # the print is hung here
FOOTER_RULE_Y = CANVAS_H - 214  # colophon rule; logo centred beneath
LOGO_WIDTH = 340

# The caption placard sits under the print: a gap, the state word, then the
# subtitle. Named because print_rect has to reserve room for it and the
# legibility bands have to find it, and three copies of "34" would drift.
PLACARD_TOP_GAP = 34
PLACARD_BLOCK_H = 66           # word at +0, subtitle at +32, descenders below

#: The tallest a print may be before its caption would reach the colophon rule.
#:
#: Unbounded until #322. A 2:3 portrait produced a 1404px print and put the
#: caption at y=1920, past the rule at 1706 and off the bottom of the canvas,
#: and nothing refused it: the reel rendered broken and reported success.
MAX_PRINT_H = FOOTER_RULE_Y - PRINT_Y - PLACARD_TOP_GAP - PLACARD_BLOCK_H


def print_rect(photo_size: tuple[int, int]) -> tuple[int, int, int, int]:
    """Where the print hangs for a photo of `photo_size`: (left, top, w, h).

    A pure function of the photograph's shape (#323). It used to be a module
    global that `prepare_photo` overwrote on every call, which the renderer read
    to place the caption and the tests read back to work out where the caption
    should be. Expected position and drawn position came from one value, so a
    wrong height moved both together and every check passed hardest at exactly
    the moment the layout was broken (L70). It also meant preparing two photos
    kept only the second one's height, so a RAW and an edit of different shapes
    put the caption under the wrong one.

    Fills the plate's width for anything landscape or moderately tall. A photo
    tall enough that its caption would reach the colophon is narrowed from the
    height cap and re-centred, rather than cropped to a shape Dan did not
    choose: he frames these, and silently changing the crop is a worse answer
    than a smaller print.
    """
    width, height = photo_size
    aspect = width / height
    print_h = int(PRINT_W / aspect)
    if print_h <= MAX_PRINT_H:
        return ((CANVAS_W - PRINT_W) // 2, PRINT_Y, PRINT_W, print_h)
    print_w = int(MAX_PRINT_H * aspect)
    return ((CANVAS_W - print_w) // 2, PRINT_Y, print_w, MAX_PRINT_H)


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        return ImageFont.load_default()


def tracked(draw, text, font, fill, x, y, spacing):
    """Left-aligned, letter-spaced text: the program-plate look."""
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        b = draw.textbbox((0, 0), ch, font=font)
        x += (b[2] - b[0]) + spacing


def hang_print(photo: Image.Image, rect: tuple[int, int, int, int]) -> Image.Image:
    """Hang `photo` as a matted print on the cream mat, in `rect`.

    A soft drop shadow and a cream hairline make it read as a print on paper.
    Every state of a reel uses the SAME rectangle, so a reveal only shows where
    there is a print to divide; the surrounding mat is cream-over-cream and
    stays still.
    """
    left, top, width, height = rect

    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (*CREAM, 255))
    shadow = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rectangle(
        [left + 3, top + 6, left + width + 3, top + height + 8],
        fill=(60, 55, 50, 44))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))

    canvas.paste(photo.resize((width, height), Image.LANCZOS).convert("RGBA"),
                 (left, top))
    ImageDraw.Draw(canvas).rectangle(
        [left - 1, top - 1, left + width, top + height],
        outline=CREAM_EDGE, width=1)
    return canvas.convert("RGB")


def smoothstep(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def placard_alphas(progress: float) -> tuple[float, float]:
    """Opacity of the outgoing and incoming captions at `progress` through a reveal.

    Dissolves THROUGH EMPTY: the first word fades out before the second fades
    in. A straight cross-dissolve would overlap two different words in one spot
    and read as garbled, so they never coexist.

    Pure, which is the point. It replaces two module globals that one renderer
    wrote and another would have read, the same defect class the print rectangle
    was fixed for.

    Two captions, not a general number of them. A reel with three states
    crossfades them a pair at a time, once per sweep, so a general version would
    ship a branch nothing calls (L46).
    """
    return (smoothstep((0.48 - progress) / 0.18),
            smoothstep((progress - 0.52) / 0.18))


def draw_placard(canvas_rgba, rect, state: str, alpha: float):
    """One caption placard under the print, at `alpha`."""
    if alpha <= 0.003:
        return canvas_rgba
    word, subtitle = placard_text(state)
    layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    y = rect[1] + rect[3] + PLACARD_TOP_GAP
    tracked(d, word, load_font(FONT_DETAIL, 20, index=FONT_DETAIL_BOLD),
            (*ROSE_GOLD, 255), MAT, y, 6)
    tracked(d, subtitle, load_font(FONT_DETAIL, 14, index=FONT_DETAIL_MEDIUM),
            (*WARM_MID, 255), MAT, y + 32, 4)
    if alpha < 1.0:
        layer.putalpha(layer.split()[3].point(lambda a: int(a * alpha)))
    return Image.alpha_composite(canvas_rgba, layer)


def draw_plate_chrome(frame, event_name: str, org: str, venue: str, logo,
                      rect: tuple[int, int, int, int],
                      placards: list[tuple[str, float]]):
    """Masthead, both rose-gold rules, footer colophon, and the captions.

    `placards` is (state, alpha) per caption, so the caller decides how many
    states there are and where in the dissolve each one is.
    """
    c = frame.convert("RGBA")
    d = ImageDraw.Draw(c)

    # Masthead, top-left, shifted down so it isn't jammed at the very edge.
    d.text((MAT, MASTHEAD_Y), event_name, font=load_font(FONT_SCRIPT, 74), fill=TEXT_DARK)
    lines = detail_lines(event_name, org, venue)
    if lines:
        tracked(d, lines[0].upper(),
                load_font(FONT_DETAIL, 19, index=FONT_DETAIL_LIGHT), WARM_MID,
                MAT, VENUE_Y, 5)
    d.line([(MAT, RULE_Y), (CANVAS_W - MAT, RULE_Y)], fill=ROSE_GOLD, width=1)

    # Footer colophon closing the bottom.
    d.line([(MAT, FOOTER_RULE_Y), (CANVAS_W - MAT, FOOTER_RULE_Y)],
           fill=ROSE_GOLD, width=1)
    if logo:
        c.alpha_composite(logo, ((CANVAS_W - logo.width) // 2, FOOTER_RULE_Y + 40))

    for state, alpha in placards:
        c = draw_placard(c, rect, state, alpha)
    return c.convert("RGB")


def load_logo(logo_path: str | None, width: int = LOGO_WIDTH):
    """The wordmark scaled to the plate's colophon width, or None.

    Kept as the plate's own name for the shared loader, because both reels and
    their tests reach the mark through here. A path that is set and not on disk
    raises rather than returning None: this used to swallow it and hang a
    plate with no signature (#334).
    """
    from .wordmark import load
    return load(logo_path, width)
