"""#162: the brand palette is stated once, and the Swift mirror agrees with it.

Cream, rose gold, the warm text colours and the mat scale used to be
copy-pasted independently into every media generator. Nothing stopped them
drifting, and two pairs already had: the print hairline was 214,208,200 in the
collage and the scroll reel but 212,201,192 in the before/after and the morph
reel, and `ROSE_GOLD` named 196,135,122 in the story template and 160,105,95 in
five others. A brand change had to be found and applied by hand in each file,
and a missed one silently shipped an off-brand asset.

These tests hold the consolidation in place. The first two fail if a generator
grows its own copy of a shared value again; the third fails if the Swift mirror
and the Python source disagree, which is the seam that has no compiler and no
import to keep it honest.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from postroll.media import design_tokens as tokens


REPO_ROOT = Path(__file__).resolve().parent.parent
MEDIA = REPO_ROOT / "postroll" / "media"
SWIFT_TOKENS = REPO_ROOT / "PostRollApp" / "Sources" / "DesignTokens.swift"
COLLAGE_GEOMETRY = REPO_ROOT / "PostRollApp" / "Sources" / "Services" / "CollageGeometry.swift"


def _generators() -> list[Path]:
    """The generator modules, which is everything in media/ but the tokens."""
    found = [
        p for p in sorted(MEDIA.glob("*.py"))
        if p.name not in {"design_tokens.py", "__init__.py"}
    ]
    assert len(found) > 5, (
        "found almost no generator modules, so these scans would pass by "
        "scanning nothing")
    return found


# ── nobody keeps a private copy ───────────────────────────────────────────────

def test_no_generator_defines_a_brand_colour_of_its_own():
    # Matched by VALUE rather than by name, because the drift that prompted
    # this was two files giving one colour two different names.
    shared = {
        tokens.CREAM: "CREAM",
        tokens.CREAM_EDGE: "CREAM_EDGE",
        tokens.HAIRLINE: "HAIRLINE",
        tokens.TEXT_DARK: "TEXT_DARK",
        tokens.WARM_MID: "WARM_MID",
        tokens.ROSE_GOLD: "ROSE_GOLD",
        tokens.ROSE_GOLD_LIGHT: "ROSE_GOLD_LIGHT",
    }
    literal = re.compile(r"^([A-Z_]+)\s*=\s*\((\d+),\s*(\d+),\s*(\d+)\)", re.M)

    offenders = []
    for source in _generators():
        for match in literal.finditer(source.read_text()):
            rgb = tuple(int(g) for g in match.group(2, 3, 4))
            if rgb in shared:
                offenders.append(
                    f"{source.name}:{match.group(1)} = {rgb} "
                    f"(import {shared[rgb]} from design_tokens)")

    assert not offenders, "brand colours redefined locally:\n  " + "\n  ".join(offenders)


def test_no_generator_hardcodes_the_font_files():
    offenders = []
    for source in _generators():
        text = source.read_text()
        for path in (tokens.FONT_SCRIPT, tokens.FONT_DETAIL):
            if f'"{path}"' in text:
                offenders.append(f"{source.name} hardcodes {path}")

    assert not offenders, "font paths restated locally:\n  " + "\n  ".join(offenders)


def test_every_generator_that_paints_brand_chrome_imports_the_tokens():
    # The scans above are satisfied by a file that stopped painting entirely,
    # so this asserts the positive: the templates still get their values from
    # the one module.
    painters = [
        "generate_collage.py", "generate_story.py", "generate_before_after.py",
        "generate_reel_scroll.py", "generate_reel_slider.py",
        "generate_reel_morph.py", "generate_reel_screen.py",
    ]
    for name in painters:
        source = MEDIA / name
        assert source.is_file(), f"{name} has moved; this list needs updating"
        assert "design_tokens" in source.read_text(), (
            f"{name} paints brand chrome but does not import the tokens")


# ── the Swift mirror ──────────────────────────────────────────────────────────

def _swift_colours(text: str) -> dict[str, tuple[int, int, int]]:
    pattern = re.compile(
        r"static let (\w+)\s*=\s*Color\(red:\s*(\d+)\s*/\s*255,"
        r"\s*green:\s*(\d+)\s*/\s*255,\s*blue:\s*(\d+)\s*/\s*255\)")
    return {
        m.group(1): tuple(int(g) for g in m.group(2, 3, 4))
        for m in pattern.finditer(text)
    }


# Swift's name for each shared Python token. Only the ones that genuinely mean
# the same thing: the app also carries surface colours (creamDeep, warmFaint,
# the stage pills) that no generator paints, and those stay Swift-only.
MIRRORED = {
    "cream":     "CREAM",
    "creamEdge": "CREAM_EDGE",
    "hairline":  "HAIRLINE",
    "roseGold":  "ROSE_GOLD",
    "warmDark":  "TEXT_DARK",
    "warmMid":   "WARM_MID",
}


@pytest.mark.parametrize("swift_name,python_name", sorted(MIRRORED.items()))
def test_the_swift_mirror_agrees_with_the_python_tokens(swift_name, python_name):
    colours = _swift_colours(SWIFT_TOKENS.read_text())
    assert swift_name in colours, (
        f"DesignTokens.swift no longer declares `{swift_name}`; the Python "
        f"token {python_name} now has no mirror and can drift unnoticed")
    assert colours[swift_name] == getattr(tokens, python_name), (
        f"Swift `{swift_name}` is {colours[swift_name]} but Python "
        f"{python_name} is {getattr(tokens, python_name)}; the app and the "
        f"exported asset would not match")


def test_the_collage_hairline_is_not_declared_a_second_time_in_swift():
    # It was declared privately on CollageGeometry, which is how the Swift side
    # came to hold a hairline the before/after and morph templates did not.
    text = COLLAGE_GEOMETRY.read_text()
    assert "Color(red:" not in text, (
        "CollageGeometry declares a colour of its own; brand colours belong in "
        "DesignTokens.swift so the parity test above can see them")
