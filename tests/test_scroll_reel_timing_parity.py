"""#1076: the Thursday reel's timing is one contract, read by both languages.

Before anything is rendered the editor has to answer two questions: how long
the reel will be, so it can say whether the chosen track covers it, and how
fast it will scroll, so it can say whether that is comfortable to watch. Both
are functions of constants in `postroll/media/generate_reel_scroll.py`, asked on
the Swift side, with nothing forcing the two to agree.

That is the split that put an 8px gutter in the collage editor against Python's
16 (#969). `tests/fixtures/scroll_reel_timing.json` states the numbers once,
written by `tools/record_scroll_reel_timing.py`. This file asserts Python still
renders with them; `PostRollApp/Tests/ScrollReelTimingTests.swift` asserts the
editor still computes from them.

The reel length is the trap worth naming. A reel is the scroll a person chose
PLUS a hold at the bottom PLUS the closing frame, so a track that comfortably
covers the scroll can still be six seconds short of the reel, and a warning
computed against the slider value alone would say nothing on exactly the reels
that loop.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.media import generate_reel_scroll as scroll
from postroll.media.easing import cruise_factor


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "scroll_reel_timing.json"


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text())


def test_the_contract_is_not_empty():
    doc = _fixture()
    assert doc["reel_seconds_for_scroll"], "the contract has lost its lengths"
    assert len(doc["reel_seconds_for_scroll"]) >= 5


@pytest.mark.parametrize("key,value", [
    ("hold_end_s", "HOLD_END"),
    ("closing_frame_s", "CLOSING_FRAME_DURATION"),
    ("fps", "FPS"),
    ("viewport_h", "VIEWPORT_H"),
    ("ease_ramp", "EASE_RAMP"),
])
def test_the_contract_states_what_the_renderer_uses(key, value):
    assert _fixture()[key] == getattr(scroll, value), (
        f"the contract says {key} is {_fixture()[key]} and the renderer's "
        f"{value} is {getattr(scroll, value)}. Every number the editor shows is "
        f"now computed from something the reel does not do, so regenerate the "
        f"fixture with tools/record_scroll_reel_timing.py.")


def test_the_cruise_factor_is_the_one_the_easing_actually_reaches():
    """Not restated: measured off the curve the renderer walks (L107).

    The warning about a reel being too fast is computed from this, so if the
    easing's ramp moves, every warning is wrong by the same proportion and
    nothing else here would notice.
    """
    doc = _fixture()
    assert doc["cruise_factor"] == pytest.approx(cruise_factor(scroll.EASE_RAMP))

    samples = 4000
    travel = scroll.max_scroll_for(29000)
    positions = [scroll.ease_in_out(i / samples) * travel for i in range(samples + 1)]
    peak = max(b - a for a, b in zip(positions, positions[1:])) * samples
    assert peak / travel == pytest.approx(doc["cruise_factor"], rel=0.01), (
        "the curve does not cruise at the factor the contract states")


def test_a_reel_is_the_scroll_plus_the_holds():
    """The recorded lengths are what the renderer actually encodes.

    Asserted against the renderer's own arithmetic rather than by adding the
    two constants again here, which would be a second implementation agreeing
    with itself.
    """
    doc = _fixture()
    for scroll_seconds, reel_seconds in doc["reel_seconds_for_scroll"].items():
        expected = (float(scroll_seconds) + scroll.HOLD_END
                    + scroll.CLOSING_FRAME_DURATION)
        assert reel_seconds == pytest.approx(expected), (
            f"a {scroll_seconds}s scroll is recorded as a {reel_seconds}s reel, "
            f"not the {expected}s it renders as")
        assert reel_seconds > float(scroll_seconds), (
            "a reel that is no longer than its scroll would make the holds "
            "invisible to any warning computed from this")


def test_the_slider_range_in_the_contract_is_the_one_the_editor_offers():
    """A contract describing a slider nobody has would produce warnings about
    lengths that cannot be chosen."""
    swift = (Path(__file__).resolve().parent.parent / "PostRollApp" / "Sources"
             / "Views" / "PhotoAssignmentView.swift").read_text()
    doc = _fixture()["slider"]
    wanted = (f"Slider(value: $scrollDuration, in: {doc['min_s']:g}...{doc['max_s']:g}, "
              f"step: {doc['step_s']:g})")
    assert wanted in swift, (
        f"the contract records a {doc['min_s']:g} to {doc['max_s']:g} slider in "
        f"steps of {doc['step_s']:g}, and PhotoAssignmentView does not declare "
        f"one: looked for {wanted!r}")
