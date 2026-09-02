"""The one easing every reel that moves is built from.

There used to be a curve per template, each written as separate formulas
stitched together at fixed points, and two of them shipped the same defect: the
slopes did not match where the pieces met, so the motion accelerated between
one frame and the next. The scroll's step was 8% and Dan reported it as a hitch
(#1061); the slider's was 75% (#1073). Sharing the DATA while copying the
formula would not have prevented either, so what is shared here is the formula
and each template supplies only its own ramp (L370).
"""

from __future__ import annotations


def smoothstep_area(u: float) -> float:
    """Area under smoothstep from 0 to `u`, both in units of the ramp width."""
    return u ** 3 - u ** 4 / 2


def cruise_factor(ramp: float) -> float:
    """How much faster than the average the constant middle section runs.

    The whole journey is covered in the same time whatever the ramp, so time
    spent below the cruise speed at each end has to be paid back in the middle.
    Warnings about how fast a reel reads are computed from this rather than
    from the average, because the middle is what a viewer is watching.
    """
    return 1.0 / (1.0 - ramp)


def trapezoid_ease(t: float, ramp: float) -> float:
    """How far through the journey the motion has travelled at `t` in [0, 1].

    A trapezoidal speed profile: smoothstep up over the first `ramp` of the
    time, constant through the middle, smoothstep down over the last `ramp`.
    Smoothstep rather than a straight ramp because its own slope is zero at
    both ends, so the speed is continuous everywhere the three pieces meet and
    there is no frame on which the motion jumps.

    `ramp` sets the character: 0 is a constant speed with a hard start, and the
    larger it is the more dramatic the difference between the ends and the
    middle. It must be under 0.5, since the two ramps have to fit in the run.
    """
    if not 0.0 <= ramp < 0.5:
        raise ValueError(
            f"ramp must be at least 0 and under 0.5, not {ramp}: the two ramps "
            f"have to fit inside the journey with a middle between them")
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0

    a = ramp
    total = 1.0 - a  # area under the speed profile, which normalises position
    if t < a:
        return a * smoothstep_area(t / a) / total
    if t <= 1.0 - a:
        return (a * 0.5 + (t - a)) / total
    return 1.0 - a * smoothstep_area((1.0 - t) / a) / total
