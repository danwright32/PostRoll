"""#169: the Tuesday screen reel's wordmark must be readable on its footer.

The footer is cream at CREAM_OPACITY laid over the video, so it composites
LIGHT whatever is underneath. A white mark on it washes out, worst over bright
footage, and a bright-stage event would ship a reel with a barely visible
signature.

This is the fourth time white-on-cream has shipped invisibly in this project,
which is why the check is a measured pixel contrast rather than a reading of
the code: the mark's colour has to be checked against the surface it actually
lands on, over both a dark and a bright frame.
"""

from __future__ import annotations

from PIL import Image

from postroll.media import generate_reel_screen as screen


def _relative_luminance(rgb) -> float:
    """WCAG relative luminance, 0 (black) to 1 (white)."""
    def channel(v: float) -> float:
        v = v / 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(c) for c in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _contrast(a, b) -> float:
    la, lb = _relative_luminance(a), _relative_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def _footer_surface_over(video_value: int):
    """The colour the cream footer composites to over a frame of this value.

    Measured by compositing, not assumed: the footer is semi-transparent, so
    what the mark sits on depends on the footage beneath it.
    """
    frame = Image.new("RGBA", (screen.CANVAS_W, screen.CANVAS_H),
                      (video_value, video_value, video_value, 255))
    footer = Image.new("RGBA", (screen.CANVAS_W, screen.FOOTER_H),
                       (*screen.CREAM, screen.CREAM_OPACITY))
    frame.paste(footer, (0, screen.CANVAS_H - screen.FOOTER_H), footer)
    return frame.getpixel((screen.CANVAS_W // 2, screen.CANVAS_H - screen.FOOTER_H // 2))


def test_the_footer_is_light_over_dark_footage():
    surface = _footer_surface_over(0)
    assert _relative_luminance(surface) > 0.4, (
        f"the footer composites to {surface}, which is not the light surface "
        "the mark colour is chosen for"
    )


def test_the_footer_is_light_over_bright_footage():
    surface = _footer_surface_over(255)
    assert _relative_luminance(surface) > 0.4, surface


def test_a_white_mark_fails_on_that_footer_over_both_extremes():
    """The bug, stated as a measurement. If this ever stops failing, the footer
    has changed and the whole rule needs revisiting."""
    for value in (0, 255):
        surface = _footer_surface_over(value)
        assert _contrast((255, 255, 255), surface) < 3.0, (
            f"white on {surface} would actually be readable, so the premise of "
            "this fix no longer holds"
        )


def test_a_dark_mark_is_readable_on_that_footer_over_both_extremes():
    for value in (0, 128, 255):
        surface = _footer_surface_over(value)
        assert _contrast((0, 0, 0), surface) >= 4.5, (
            f"the dark mark only reaches {_contrast((0, 0, 0), surface):.1f} to 1 "
            f"on {surface}"
        )


def test_the_screen_reel_is_given_the_dark_mark():
    """Built is not wired: the contrast maths above is worth nothing if the
    generator is still handed the white file."""
    import inspect
    from postroll.ai import generate_media

    lines = inspect.getsource(generate_media).split("\n")
    starts = [i for i, l in enumerate(lines) if "generate_reel_screen(" in l and "import" not in l]
    assert len(starts) == 1, f"expected one call site, found {len(starts)}"

    # A line window rather than paren matching: the argument list carries
    # comments, and an issue number in one of them is a close paren.
    call = "\n".join(lines[starts[0]:starts[0] + 25])
    assert "logo_path=" in call, f"the window missed the argument list:\n{call}"
    assert "LOGO_BLACK" in call, f"the screen reel is not given the dark mark:\n{call}"
    assert "logo_path=LOGO_WHITE" not in call, (
        f"the screen reel is still given the white mark:\n{call}")
