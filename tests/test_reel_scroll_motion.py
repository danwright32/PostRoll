"""How the scroll MOVES, as distinct from what it draws.

The reel this was reported on (Battery Dance Festival, 234 photos, a 29,000px
strip, a 35s scroll) advanced 30.4 pixels between frames at cruise, measured
both from the generator and by cross correlating consecutive frames of the
delivered mp4 on 2026-08-30. The photography viewport is 1430px, so the whole
visible gallery was replaced every 1.6 seconds. Past roughly 8 to 12 pixels a
frame the eye stops fusing successive frames into motion and starts seeing the
jumps, which is what "jittery" was describing.

Three separate things were wrong. Only the last two belong to the renderer, and
each has its own check here, because a single "does it look smooth" reading
would be satisfied by fixing any one of them (L11, L178):

1. the strip moved too far between frames, which is not a renderer defect: it
   is 234 photographs in 35 seconds, and belongs to #1064 and #1066;
2. `int(eased * max_scroll)` truncated a 30.4px step to an alternating 30, 31,
   so the speed wobbled a few percent on EVERY frame;
3. `ease_in_out` was piecewise with a genuine velocity discontinuity at its
   seams: 33px a frame either side of t=0.12 dropping instantly to 30, and the
   mirror of it at t=0.88. Two visible lurches per reel, measured in the
   delivered file at 4.2s.
"""

from __future__ import annotations

import random

import pytest
from PIL import Image, ImageChops

from postroll.media import generate_reel_scroll as scroll_mod


#: The reel the defect was reported on, so the ceiling below is judged against
#: a real journey rather than a shape chosen to pass (L48).
REPORTED_STRIP_H = 29000
REPORTED_DURATION = 35.0

#: What a frame may advance before the scroll reads as rushed, in the units the
#: renderer works in and at the frame rate that actually ships.
#:
#: Not chosen from theory. Dan judged a ladder of the reported reel on
#: 2026-08-30, one layout, one photo set, speed the only variable: 11.50 px a
#: frame read as fast and 10.81 read as right. Instagram re-encodes every reel
#: to 30fps regardless of what it is given, so these are the numbers a viewer
#: sees rather than numbers only the master has.
COMFORTABLE_TRAVEL_PX = 10.81

#: What the reported reel needs to reach that speed, given its 234 photographs.
#: Its shipped 35s is a third of this, which is the defect, and the fix belongs
#: to the photo count and the duration rather than to anything in here.
COMFORTABLE_DURATION_S = 100.0

EVENT = ("Battery Dance Festival", "Battery Dance", "Wagner Park")


def scroll_positions(strip_height: int, duration: float) -> list[float]:
    """Where the strip sits on each frame of the scroll, in order.

    Read out of the generator's own easing and frame rate rather than restated,
    so a check cannot pass while the encoder walks a different journey (L107).
    """
    n = int(duration * scroll_mod.FPS)
    travel = scroll_mod.max_scroll_for(strip_height)
    return [scroll_mod.ease_in_out(i / n) * travel for i in range(n + 1)]


def test_a_reel_sized_for_comfort_scrolls_at_the_speed_it_was_sized_for():
    """The renderer does not choose the speed, but it must not alter it.

    How fast a reel scrolls comes from the photo count and the duration, both of
    which are the user's. This file cannot assert a ceiling on that: it did,
    briefly, and the assertion was really about how many photographs somebody
    picked (#1064, #1066).

    What the renderer DOES own is the easing, whose cruise factor turns the
    average speed into the peak. #1066's warning is computed from that factor,
    so if `EASE_RAMP` moves, every warning it produces is wrong by the same
    proportion and nothing else here would notice.
    """
    steps = scroll_positions(REPORTED_STRIP_H, COMFORTABLE_DURATION_S)
    worst = max(b - a for a, b in zip(steps, steps[1:]))
    assert worst == pytest.approx(COMFORTABLE_TRAVEL_PX, rel=0.02), (
        f"a {REPORTED_STRIP_H}px strip over {COMFORTABLE_DURATION_S}s advances "
        f"{worst:.2f}px a frame, not the {COMFORTABLE_TRAVEL_PX}px it was sized "
        f"for. The easing's cruise factor has moved, so every speed warning "
        f"derived from it is now wrong by the same proportion.")


def test_the_scroll_has_no_lurch_in_it():
    """Velocity may change, but never in a step.

    The old curve was three formulas stitched together and its velocity jumped
    about 8% at each seam. Sampled finely enough that a smooth curve's own
    change between samples is far below the tolerance, so this is a check on
    the seam rather than on the sampling.
    """
    n = 2000
    travel = scroll_mod.max_scroll_for(REPORTED_STRIP_H)
    pos = [scroll_mod.ease_in_out(i / n) * travel for i in range(n + 1)]
    vel = [(b - a) * n for a, b in zip(pos, pos[1:])]
    jumps = [abs(b - a) for a, b in zip(vel, vel[1:])]

    worst = max(jumps)
    where = jumps.index(worst) / n
    # A smooth profile changes velocity by at most a few tenths of a pixel per
    # sample at this sampling rate; a seam changes it by thousands.
    assert worst < travel * 0.02, (
        f"velocity jumps by {worst:.0f}px/s at t={where:.3f}, which is a lurch "
        f"the viewer sees. The scroll may accelerate, but smoothly.")


def test_the_scroll_actually_travels_the_whole_strip():
    """The guard above is satisfied by a scroll that never moves (L159).

    So the positive case is asserted in the same file: the journey still starts
    at the top and ends at the bottom, and only moves forwards.
    """
    steps = scroll_positions(REPORTED_STRIP_H, REPORTED_DURATION)
    travel = scroll_mod.max_scroll_for(REPORTED_STRIP_H)
    assert steps[0] == pytest.approx(0, abs=0.5)
    assert steps[-1] == pytest.approx(travel, abs=0.5)
    assert all(b >= a for a, b in zip(steps, steps[1:])), "the scroll goes backwards"


# ── Sub-pixel positioning ────────────────────────────────────────────────────

def _textured(height: int = 3000) -> Image.Image:
    """A strip whose brightness changes from row to row at every scale.

    Deliberately not a repeating stripe: a periodic pattern can come out of a
    short blur with as much row to row contrast as it went in with, at a
    different frequency, so a check on detail would read a real blur as no
    blur. Seeded, so the readings are the same on every run.
    """
    rng = random.Random(20260830)
    rows = [rng.randrange(20, 240) for _ in range(height)]
    strip = Image.new("RGB", (scroll_mod.CANVAS_W, height))
    strip.putdata([(v, v, v) for v in rows for _ in range(scroll_mod.CANVAS_W)])
    return strip


@pytest.fixture(scope="module")
def textured() -> Image.Image:
    return _textured()


def test_a_fractional_scroll_lands_between_two_whole_pixels(textured):
    """Truncating to whole pixels is what made the speed wobble frame to frame.

    A half pixel offset has to be a real, different picture, and one that sits
    between its neighbours rather than snapping to either.
    """
    low = scroll_mod.place_strip(textured, 100)
    high = scroll_mod.place_strip(textured, 101)
    mid = scroll_mod.place_strip(textured, 100.5)

    assert ImageChops.difference(mid, low).getbbox() is not None, \
        "a half pixel scroll rendered the same picture as the whole one below it"
    assert ImageChops.difference(mid, high).getbbox() is not None, \
        "a half pixel scroll rendered the same picture as the whole one above it"

    expected = Image.blend(low, high, 0.5)
    diff = ImageChops.difference(mid, expected).convert("L")
    assert diff.getextrema()[1] <= 1, \
        "a half pixel scroll is not the blend of the two whole pixels it sits between"


def test_a_whole_number_scroll_is_unchanged_by_sub_pixel_support(textured):
    """Existing readings pass whole numbers. They must get exactly what they did."""
    for y in (0, 137, scroll_mod.max_scroll_for(textured.height)):
        assert ImageChops.difference(
            scroll_mod.place_strip(textured, y),
            scroll_mod.place_strip(textured, float(y))).getbbox() is None


def test_the_bottom_of_the_strip_is_never_read_past(textured):
    """A fractional offset reads the row below too, and past the last row that
    is black rather than photography. Clamped, not padded."""
    end = scroll_mod.max_scroll_for(textured.height)
    frame = scroll_mod.place_strip(textured, end - 0.5)
    bottom = frame.crop((0, scroll_mod.VIEWPORT_BOTTOM - 2,
                         scroll_mod.CANVAS_W, scroll_mod.VIEWPORT_BOTTOM))
    assert bottom.getextrema()[0][1] > 0, \
        "the last rows of the viewport are black: the crop read past the strip"
