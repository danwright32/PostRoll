"""No reel template's motion may change speed in a step.

Every reel that moves does it through a module level `ease_in_out`, and two of
the three have now shipped the same defect: a curve assembled from separate
formulas whose slopes do not match where they meet, so the motion accelerates
between one frame and the next. The scroll's step was 8% and Dan reported it as
a hitch (#1061); the slider's was 75% (#1073).

So the rule is held over every reel module that has an easing, discovered by
reading the package rather than listed here, because a list is exactly what a
new template is added without (L96, L41).
"""

from __future__ import annotations

import importlib
import pathlib

import pytest

import postroll.media
from postroll.media import easing


#: Fine enough that a smooth curve's own change between samples is far below
#: the tolerance, so a failure is the seam rather than the sampling.
SAMPLES = 4000

#: A step big enough to see. The two real ones were 8% and 75% of the average
#: speed; a smooth curve at this sampling rate changes by under 0.2%.
MAX_VELOCITY_STEP = 0.02


def _reel_easings() -> list[tuple[str, object]]:
    """Every reel module that owns an easing, and the function itself."""
    here = pathlib.Path(postroll.media.__path__[0])
    found = []
    for path in sorted(here.glob("generate_reel_*.py")):
        module = importlib.import_module(f"postroll.media.{path.stem}")
        fn = getattr(module, "ease_in_out", None)
        if fn is not None:
            found.append((path.stem, fn))
    return found


def _velocities(fn) -> list[float]:
    """Speed between successive samples, in units of the average speed."""
    pos = [fn(i / SAMPLES) for i in range(SAMPLES + 1)]
    return [(b - a) * SAMPLES for a, b in zip(pos, pos[1:])]


def test_the_reel_modules_that_move_were_actually_found():
    """The sweep below is satisfied by finding nothing at all (L98).

    Both templates that have had this defect must be among what it examines, or
    a rename turns the whole file green while checking no easing.
    """
    names = [name for name, _ in _reel_easings()]
    assert "generate_reel_scroll" in names
    assert "generate_reel_slider" in names


@pytest.mark.parametrize("name,fn", _reel_easings(), ids=lambda v: v if isinstance(v, str) else "")
def test_no_reel_changes_speed_in_a_step(name, fn):
    velocities = _velocities(fn)
    jumps = [abs(b - a) for a, b in zip(velocities, velocities[1:])]
    worst = max(jumps)
    where = jumps.index(worst) / SAMPLES
    assert worst < MAX_VELOCITY_STEP, (
        f"{name}.ease_in_out accelerates by {worst * 100:.0f}% of its average "
        f"speed between two samples at t={where:.3f}. The motion may change "
        f"speed, but not in a step: a viewer sees that as a lurch.")


@pytest.mark.parametrize("name,fn", _reel_easings(), ids=lambda v: v if isinstance(v, str) else "")
def test_every_reel_easing_actually_travels(name, fn):
    """The check above is satisfied by a curve that never moves (L159)."""
    pos = [fn(i / SAMPLES) for i in range(SAMPLES + 1)]
    assert pos[0] == pytest.approx(0.0, abs=1e-9), f"{name} does not start at the start"
    assert pos[-1] == pytest.approx(1.0, abs=1e-9), f"{name} does not reach the end"
    assert all(b >= a for a, b in zip(pos, pos[1:])), f"{name} travels backwards"


def test_the_sliders_sweep_is_still_as_dramatic_as_it_was():
    """Removing the step must not quietly remove the drama with it.

    The curve this replaced covered 70% of the print in the middle 40% of the
    sweep, so it cruised at 1.75 times the average. That was the intent and it
    was never the defect. Nothing else here would notice the ramp being copied
    from the scroll, which would leave the sweep correct, smooth, and a
    completely different move.
    """
    from postroll.media import generate_reel_slider as slider_mod

    velocities = _velocities(slider_mod.ease_in_out)
    assert max(velocities) == pytest.approx(1.75, rel=0.01), (
        f"the sweep now cruises at {max(velocities):.2f} times its average "
        f"speed, not the 1.75 it was drawn at.")
    assert easing.cruise_factor(slider_mod.EASE_RAMP) == pytest.approx(
        max(velocities), rel=0.01), (
        "cruise_factor disagrees with the curve it describes, so every warning "
        "computed from it is wrong by that proportion")


@pytest.mark.parametrize("ramp", [0.5, 0.6, 1.0, -0.01])
def test_a_ramp_that_cannot_fit_inside_the_journey_is_refused(ramp):
    """Two ramps of half the run each leave no middle, and past that they
    overlap. Returning some nearby curve instead would give a template a
    silently different move from the one its constant asks for."""
    with pytest.raises(ValueError, match="ramp"):
        easing.trapezoid_ease(0.5, ramp)
