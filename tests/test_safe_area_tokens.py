"""The app and the generators agree about what the phone covers (#753, #758).

`design_tokens.SAFE_TOP`, `SAFE_BOTTOM`, `SAFE_RIGHT` and `SAFE_RIGHT_FROM` say
how much of a 1080 by 1920 frame the phone's own furniture and Instagram's
chrome are drawn over. Python holds the measurement and every template is held
to it by `tests/test_phone_safe_area.py`.

The app needs the same four numbers, because the caption review screen is where
a template that puts something in a covered band has to become visible BEFORE it
is published. That gap is how #752 survived: the show title was printed under
the clock on every scroll reel published, every local render looked perfect, and
the only detector was Dan seeing a live story on his phone.

Swift cannot import the Python, so the values are restated in
`DesignTokens.swift` and this is the only thing keeping the two in step. Two
tables in two languages with nothing forcing them to agree drift the first time
one is corrected, and the app would then draw a reassuring overlay in the wrong
place, which is worse than drawing none: it would say a template was clear when
it was not (L11, L58).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from postroll.media import design_tokens as tokens
from tests.source_text import swift_without_comments

REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT_TOKENS = REPO_ROOT / "PostRollApp" / "Sources" / "DesignTokens.swift"

#: The Python name for each Swift property, which is the pairing this file is
#: about. Written once and read by every check below, so a token added to one
#: side and not the other fails rather than being quietly half-covered.
PAIRS = {
    "top": "SAFE_TOP",
    "bottom": "SAFE_BOTTOM",
    "right": "SAFE_RIGHT",
    "rightFrom": "SAFE_RIGHT_FROM",
}


def swift_safe_area() -> dict[str, float]:
    """The four numbers as the app has them.

    Comments stripped first, or a commented-out old value carrying the marker
    decides what this reads (#436).
    """
    text = swift_without_comments(SWIFT_TOKENS.read_text(encoding="utf-8"))
    start = text.find("enum PhoneSafeArea {")
    assert start != -1, (
        "DesignTokens.swift has no PhoneSafeArea, so the app has no idea what "
        "the phone covers and the preview overlay is drawing from nothing")
    body = text[start:text.index("\n}", start)]

    found = {}
    for name in PAIRS:
        match = re.search(rf"static let {name}: CGFloat = ([0-9.]+)", body)
        assert match, f"PhoneSafeArea has no `{name}`"
        found[name] = float(match.group(1))
    return found


def test_python_declares_every_safe_area_token():
    """The source side, first. A check comparing two sides is satisfied by both
    of them being empty (L98)."""
    for python_name in PAIRS.values():
        value = getattr(tokens, python_name, None)
        assert isinstance(value, (int, float)), (
            f"design_tokens has no numeric {python_name}")
        assert value > 0, f"{python_name} is {value}, which covers nothing"


@pytest.mark.parametrize("swift_name,python_name", sorted(PAIRS.items()))
def test_swift_mirrors_the_python_value(swift_name, python_name):
    assert swift_safe_area()[swift_name] == pytest.approx(
        getattr(tokens, python_name)), (
        f"PhoneSafeArea.{swift_name} and design_tokens.{python_name} disagree. "
        "The app would then draw the covered bands in the wrong place on the "
        "preview, which is worse than drawing none: it would report a template "
        "as clear when it is not.")


def test_the_swift_reader_would_notice_a_missing_token():
    """The control for the reader above.

    Every assertion in this file is built on `swift_safe_area()` finding
    things. A reader that had stopped matching would fail loudly here rather
    than reporting agreement about an empty set (L98, L159).
    """
    found = swift_safe_area()

    assert set(found) == set(PAIRS)
    assert all(value > 0 for value in found.values())


def test_the_bands_fit_inside_the_frame_they_describe():
    """They are canvas pixels of one 1080 by 1920 frame, and two of them are
    measured from opposite edges, so a pair that overlapped would be describing
    a frame with no usable middle at all."""
    assert tokens.SAFE_TOP + tokens.SAFE_BOTTOM < 1920
    assert tokens.SAFE_RIGHT < 1080
    assert 0 < tokens.SAFE_RIGHT_FROM < 1


def test_swift_carries_the_canvas_the_numbers_are_measured_against():
    """The numbers are canvas pixels, so a view scaling them needs the frame
    they came from. Left to the call site it would be restated per view, and
    the first one to get it wrong would draw every band in the wrong place."""
    text = swift_without_comments(SWIFT_TOKENS.read_text(encoding="utf-8"))

    assert re.search(r"static let canvas = CGSize\(width: 1080, height: 1920\)",
                     text), (
        "PhoneSafeArea does not say what frame its numbers are measured "
        "against, so every view scaling them has to know it separately")
