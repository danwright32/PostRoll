"""Every reference-frame comparison writes down what it measured (#787).

`tests/test_golden_frames.py` fails a template when more than
`MAX_CHANGED_FRACTION` of its frame differs from the committed reference. That
constant was 0.005, half a percent, when this was written. The comment beside it
said why: a moved element, a label that has lost its contrast, or a shadow
streaking the mat all cover far more of the frame than this.

Measured on 2026-08-21 while doing #753, that is not true of a moved element.
Lifting `program_plate.FOOTER_RULE_Y` by `SAFE_BOTTOM` moves the entire footer
colophon of both plate reels, the rose-gold rule and the wordmark under it, 160
pixels up the frame. The diff is 7336 pixels, 0.35% of a 1080 by 1920 canvas.
Both reels passed their reference frames unchanged.

The number cannot be fixed by picking a smaller one here. What an unchanged
render really produces has never been measured on the runner that matters. On
this Mac it is exactly nothing: with this reporting in place, all ten reference
frames read 0 of 2073600 pixels changed, so the local floor is zero and there is
no distribution here to choose from at all. The share was allowed in the first
place for the CI runner's different ffmpeg, and a threshold set from this Mac
would be set from the machine the question is not about (L177).

So this is the measuring half, and it runs on every comparison rather than only
on the failing ones. A reading taken only when a check fails cannot tell you
where the passing ones sit, which is the whole distribution the threshold has to
be chosen from (L172).

Collecting is OPT IN, through one variable a job sets deliberately. It is not a
fallback to `GITHUB_STEP_SUMMARY`, which was the first shape and is a trap: that
variable is set on every GitHub runner, including the guard-proof job, which runs
pytest against a tree it has deliberately broken. Readings taken there are
readings of a template that is meant to be wrong, and they would be written to
that job's summary with nothing saying so. A measurement that can be taken by
accident is one that ends up in a distribution nobody chose (L191).

One line per reading, appended, because the reference frames are spread over
three matrix shards and several xdist workers and there is no moment when one
process holds them all. Where the collected file then goes is the workflow's
decision, and both jobs that collect publish it twice: to the run's summary for a
person, and to the log, because a step summary is not fetchable and a reading
only a person can open cannot answer a later question.
"""

from __future__ import annotations

import os
from pathlib import Path

#: Set to a path to collect the readings somewhere else, which is how the tests
#: for this read them back without a GitHub runner.
LOG_VARIABLE = "POSTROLL_GOLDEN_DRIFT_LOG"

def destination(environment: dict[str, str] | None = None) -> Path | None:
    """Where readings go, or None when nothing asked for them.

    One variable, set deliberately. None is an ordinary answer rather than a
    failure: an interactive local run has nowhere to put them and does not need
    one. Deliberately not a fallback to `GITHUB_STEP_SUMMARY` or to a default
    path in the checkout, for the reason the module docstring gives: a place
    that is always available is a place readings get written by accident,
    including from the job that runs pytest against a deliberately broken tree.
    """
    environment = os.environ if environment is None else environment
    value = environment.get(LOG_VARIABLE, "").strip()
    return Path(value) if value else None


def where_they_are(box: tuple[int, int, int, int] | None, changed: int) -> str:
    """How the changed pixels are arranged, said in words a reading can carry (#793).

    A count alone cannot tell scattered codec noise from a moved element, and
    that is the one question outstanding about `clip_reel`, which reads 26
    pixels on the runner while the other nine templates read 0. Reproducible to
    the pixel across two runs, so it is a property of that template's encode
    rather than randomness, and nothing establishes what it is.

    The box says WHERE and the fill says HOW SPREAD. 26 pixels inside a box of
    30 by 20 are one mark; the same 26 inside a box the size of the canvas are
    dust over the whole frame, and the two want completely different
    explanations.

    None is its own answer rather than an empty box: `getbbox()` returns None
    for a mask with nothing set, and a box of zeros would read as a real region
    at the top-left corner (L11).
    """
    if box is None:
        return "no changed region"
    left, top, right, bottom = box
    width, height = right - left, bottom - top
    area = width * height
    spread = f", {changed / area:.1%} of it" if area else ""
    return f"region {width}x{height} at ({left},{top}){spread}"


def line(name: str, changed: int, total: int,
         box: tuple[int, int, int, int] | None = None) -> str:
    """One reading, as it is written.

    Carries the raw count as well as the share. The share is what the threshold
    is compared against and the count is what it was derived from, and a record
    of shares alone could not be re-derived if the canvas size ever changed
    (L192).

    And it carries where the pixels are (#793). The comparison already builds
    the mask, so the box costs nothing to take, and without it every reading is
    a number with no way to ask what produced it.
    """
    # A markdown bullet, because a step summary renders what it is given and
    # consecutive plain lines are run together into one paragraph. A plain text
    # reader loses nothing by it.
    return (f"- {name}: {changed} of {total} px, {changed / total:.4%}, "
            f"{where_they_are(box, changed)}")


def report(name: str, changed: int, total: int, *,
           box: tuple[int, int, int, int] | None = None,
           environment: dict[str, str] | None = None) -> str | None:
    """Write one reading down, and hand back what was written.

    Returns None when nothing is collecting, so a caller can tell "written" from
    "there was nowhere to write it" rather than reading silence as success
    (L11). Appended in one write, since several xdist workers and three matrix
    shards append to the same file with nothing sequencing them.

    `box` and `environment` are keyword only. They were not when `box` was added
    (#793), and a caller passing an environment positionally would have bound a
    dict to `box` and written a reading about a region nobody measured, with
    nothing raising. A wrong argument has to be a TypeError at the call rather
    than a plausible value downstream (L168).
    """
    written = line(name, changed, total, box)
    where = destination(environment)
    if where is None:
        return None
    with where.open("a", encoding="utf-8") as handle:
        handle.write(written + "\n")
    return written
