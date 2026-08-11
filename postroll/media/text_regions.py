"""Where each template draws text, taken from that template's own constants (#298).

A band per element, not a glyph-tight box. A band is built from the numbers the
generator itself lays out with, so moving a masthead moves the check with it,
and it cannot drift out of step with a font that resolves differently on another
machine. The median of a band of mat is the mat, which is what the eye compares
the text against.

Every video template in `MEDIA_DESIGN_VERSIONS` appears below, either with its
bands or with a stated reason for having none. A template that is simply missing
would be exempt from the check written to cover it, and the suite asserts the
table is complete in both directions (L96).
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

from .frame_legibility import MovingTextRegion, TextRegion, logo_ink


def _band(x0: int, y0: int, x1: int, font_size: int, lines: int = 1,
          line_gap: int = 0) -> tuple[int, int, int, int]:
    """The rectangle a run of text at `font_size` occupies from (x0, y0).

    1.35 covers an ascender-to-descender box with the slack a script face needs.
    Bands are deliberately generous: an over-tight band that clips the glyphs
    would measure mostly mat and report a comfortable ratio for text that is not
    there.
    """
    height = int(font_size * 1.35)
    return (x0, y0, x1, y0 + height * lines + line_gap * (lines - 1))


def _scaled_logo_height(logo_path: str | Path, width: int) -> int:
    # Through the same named condition the renderers refuse on (#334), so a
    # wordmark that was asked for and is not on disk cannot produce a band list
    # with no colophon in it. A missing band and a mark drawn perfectly are
    # indistinguishable to every check downstream, which is the whole reason
    # this file exists.
    from .wordmark import required
    with Image.open(required(logo_path)) as img:
        return int(img.height * (width / img.width))


def morph_regions(print_height: int,
                  logo_path: str | Path | None) -> list[TextRegion]:
    """The Tuesday reel's program plate: masthead, venue line, placard, colophon.

    `print_height` is set from the photograph's aspect at render time, and the
    placard hangs off the bottom of the print, so it is read back from the module
    after a render rather than guessed here.
    """
    # Read from the PLATE, which is what draws these, rather than through the
    # reel module that imports it. A band whose colours came from a re-export
    # the renderer no longer reads would be measuring for ink nothing draws.
    from . import program_plate as m

    regions = [
        TextRegion("morph masthead",
                   _band(m.MAT, m.MASTHEAD_Y, m.CANVAS_W - m.MAT, 74),
                   m.TEXT_DARK),
        TextRegion("morph venue line",
                   _band(m.MAT, m.VENUE_Y, m.CANVAS_W - m.MAT, 19),
                   m.WARM_MID),
        TextRegion("morph placard state word",
                   _band(m.MAT, m.PRINT_Y + print_height + m.PLACARD_TOP_GAP,
                         m.CANVAS_W - m.MAT, 20),
                   m.ROSE_GOLD),
        TextRegion("morph placard subtitle",
                   _band(m.MAT, m.PRINT_Y + print_height + m.PLACARD_TOP_GAP + 32,
                         m.CANVAS_W - m.MAT, 14),
                   m.WARM_MID),
    ]
    if logo_path:
        height = _scaled_logo_height(logo_path, m.LOGO_WIDTH)
        regions.append(TextRegion(
            "morph colophon wordmark",
            (m.MAT, m.FOOTER_RULE_Y + 40, m.CANVAS_W - m.MAT,
             m.FOOTER_RULE_Y + 40 + height),
            logo_ink(logo_path)))
    return regions


def slider_regions(logo_path: str | Path | None,
                   print_height: int | None = None) -> list[TextRegion]:
    """The 3-photo Tuesday reel's plate: masthead, venue line, placard, colophon.

    The same plate the morph draws (#164), so the bands are the same shape. The
    placard hangs off the bottom of the print, whose height comes from the
    photograph, so it is passed in rather than guessed. Defaults to a 3:2
    photograph, which is what Dan shoots.
    """
    from . import program_plate as p

    if print_height is None:
        print_height = p.print_rect((3, 2))[3]

    regions = [
        TextRegion("slider masthead",
                   _band(p.MAT, p.MASTHEAD_Y, p.CANVAS_W - p.MAT, 74),
                   p.TEXT_DARK),
        TextRegion("slider venue line",
                   _band(p.MAT, p.VENUE_Y, p.CANVAS_W - p.MAT, 19),
                   p.WARM_MID),
        TextRegion("slider placard state word",
                   _band(p.MAT, p.PRINT_Y + print_height + p.PLACARD_TOP_GAP,
                         p.CANVAS_W - p.MAT, 20),
                   p.ROSE_GOLD),
        TextRegion("slider placard subtitle",
                   _band(p.MAT, p.PRINT_Y + print_height + p.PLACARD_TOP_GAP + 32,
                         p.CANVAS_W - p.MAT, 14),
                   p.WARM_MID),
    ]
    if logo_path:
        height = _scaled_logo_height(logo_path, p.LOGO_WIDTH)
        regions.append(TextRegion(
            "slider colophon wordmark",
            (p.MAT, p.FOOTER_RULE_Y + 40, p.CANVAS_W - p.MAT,
             p.FOOTER_RULE_Y + 40 + height),
            logo_ink(logo_path)))
    return regions


def scroll_regions() -> list[TextRegion]:
    """The scroll reel's cream header, which is pinned to the frame.

    Its colophon moves, so it is `scroll_moving_regions` below rather than a
    band here.
    """
    from . import generate_reel_scroll as s

    return [
        TextRegion("scroll title", _band(0, 35, s.CANVAS_W, 70), s.TEXT_DARK),
        TextRegion("scroll detail lines",
                   (0, 35 + int(70 * 1.35), s.CANVAS_W, s.HEADER_H),
                   s.TEXT_DARK),
    ]


def scroll_moving_regions(logo_path: str | Path | None) -> list[MovingTextRegion]:
    """The scroll reel's colophon, which travels with the strip (#306).

    Baked into the scrolling strip under the last print rather than pinned to
    the frame, so it passes through a different band on every frame. Found in
    each frame rather than declared.

    The search area comes from the generator's own numbers: the wordmark is
    centred at `LOGO_WIDTH`, and the rows searched are the ones between the
    chrome masks. Excluding the header matters rather than being tidiness: it
    carries its own dark ink on the same cream, and a search that found the
    title instead would report a comfortable reading on every frame while the
    colophon was missing entirely.
    """
    from . import generate_reel_scroll as s

    if not logo_path:
        return []

    from .wordmark import required
    logo_path = required(logo_path)   # see _scaled_logo_height (#334)
    logo_x = (s.CANVAS_W - s.LOGO_WIDTH) // 2
    return [
        MovingTextRegion(
            name="scroll colophon wordmark",
            search=(logo_x, s.HEADER_H, logo_x + s.LOGO_WIDTH,
                    s.CANVAS_H - s.FOOTER_H),
            ink=logo_ink(logo_path),
            backdrop=s.CREAM,
        )
    ]


#: Video templates with no bands here, and why. Each is a decision on the
#: record, so the gap cannot be mistaken for coverage.
UNCHECKED_TEMPLATES: dict[str, str] = {
    # Its wordmark sits on a semi-transparent cream footer over the footage, so
    # what the mark lands on depends on the video beneath it. That surface is
    # measured over both extremes by tests/test_screen_reel_logo_contrast.py,
    # which is the same measurement taken where it is decided.
    "reel_screen": "covered by tests/test_screen_reel_logo_contrast.py",
    # Friday's clip reel: the feature is retired (2026-07-09) and nothing in the
    # app routes to it, so an encoded render here would be checking a template
    # that is never produced.
    "reel_clip": "retired 2026-07-09, not rendered by the app",
    # A still, drawn by the scroll reel's own layout maths from the same
    # constants, so scroll_regions covers the design it shows.
    "reel_preview": "same layout as reel_scroll, covered there",
}
