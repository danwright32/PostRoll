"""Every reference-frame comparison writes down what it measured (#787).

`tests/test_golden_frames.py` fails a template when more than
`MAX_CHANGED_FRACTION` of its frame differs from the committed reference, and
that constant is 0.005, half a percent. The comment beside it said why: a moved
element, a label that has lost its contrast, or a shadow streaking the mat all
cover far more of the frame than this.

Measured on 2026-08-21 while doing #753, that is not true of a moved element.
Lifting `program_plate.FOOTER_RULE_Y` by `SAFE_BOTTOM` moves the entire footer
colophon of both plate reels, the rose-gold rule and the wordmark under it, 160
pixels up the frame. The diff is 7336 pixels, 0.35% of a 1080 by 1920 canvas.
Both reels passed their reference frames unchanged.

The number cannot be fixed by picking a smaller one here. What an unchanged
render really produces has never been measured on the runner that matters:
re-recording all ten references on this Mac against an unchanged design rewrote
eight of them byte for byte identically, so the local floor is zero, and the
share was allowed in the first place for the CI runner's different ffmpeg. A
threshold set from this Mac would be set from the machine the question is not
about (L177).

So this is the measuring half, and it runs on every comparison rather than only
on the failing ones. A reading taken only when a check fails cannot tell you
where the passing ones sit, which is the whole distribution the threshold has to
be chosen from (L172).

It writes to `GITHUB_STEP_SUMMARY` when there is one, which is how `tests.yml`
already records the ffmpeg version each leg ran against, so the numbers land on
the run's own summary page rather than in a log nobody opens. One line per
reading, appended, because the reference frames are spread over three matrix
shards and several xdist workers and there is no moment when one process holds
them all.
"""

from __future__ import annotations

import os
from pathlib import Path

#: Set to a path to collect the readings somewhere else, which is how the tests
#: for this read them back without a GitHub runner.
LOG_VARIABLE = "POSTROLL_GOLDEN_DRIFT_LOG"

#: The heading each reading is written under, so a person opening the summary
#: knows what the numbers are and does not have to find the code.
HEADING = (
    "reference-frame drift: pixels differing from the committed frame by more "
    "than the per-channel tolerance, as a share of the canvas (#787)")


def destination(environment: dict[str, str] | None = None) -> Path | None:
    """Where readings go, or None when nothing is collecting them.

    None is an ordinary answer rather than a failure: an interactive local run
    has nowhere to put them and does not need one. It is deliberately not a
    fallback to some default path, because a file quietly written into the
    checkout is a file nobody reads and nobody clears.
    """
    environment = os.environ if environment is None else environment
    for name in (LOG_VARIABLE, "GITHUB_STEP_SUMMARY"):
        value = environment.get(name, "").strip()
        if value:
            return Path(value)
    return None


def line(name: str, changed: int, total: int) -> str:
    """One reading, as it is written.

    Carries the raw count as well as the share. The share is what the threshold
    is compared against and the count is what it was derived from, and a record
    of shares alone could not be re-derived if the canvas size ever changed
    (L192).
    """
    # A markdown bullet, because a step summary renders what it is given and
    # consecutive plain lines are run together into one paragraph. A plain text
    # reader loses nothing by it.
    return f"- {name}: {changed} of {total} px, {changed / total:.4%}"


def report(name: str, changed: int, total: int,
           environment: dict[str, str] | None = None) -> str | None:
    """Write one reading down, and hand back what was written.

    Returns None when nothing is collecting, so a caller can tell "written" from
    "there was nowhere to write it" rather than reading silence as success
    (L11). Appended in one write, since several xdist workers and three matrix
    shards append to the same file with nothing sequencing them.
    """
    written = line(name, changed, total)
    where = destination(environment)
    if where is None:
        return None
    with where.open("a", encoding="utf-8") as handle:
        handle.write(written + "\n")
    return written
