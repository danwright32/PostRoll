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
import re
from dataclasses import dataclass
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


#: Set to a directory to KEEP the frame each comparison rendered (#827).
#:
#: `tools/record_codec_change.py` used to answer "may this frame be re-recorded"
#: by running the reference checks, and then answer "record it" by running them
#: again with `POSTROLL_UPDATE_GOLDENS` set. Two full renders of a reel for one
#: decision, and the frame it recorded was not the frame it judged, because the
#: second run rendered afresh. With the first render kept, the tool records
#: exactly what it measured and renders once.
#:
#: Opt in through a variable a tool sets deliberately, for the same reason the
#: readings are: a place that is always available is a place frames get written
#: by accident, including from the job that runs pytest against a deliberately
#: broken tree.
CANDIDATE_VARIABLE = "POSTROLL_GOLDEN_CANDIDATES"


def candidate_for(name: str, environment: dict[str, str] | None = None) -> Path | None:
    """Where this comparison's rendered frame should be kept, or None.

    Named for the reference frame rather than for the test, so a tool that has
    decided to record it can find it by the name it will write it under.
    """
    environment = os.environ if environment is None else environment
    value = environment.get(CANDIDATE_VARIABLE, "").strip()
    return Path(value) / f"{name}.png" if value else None


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


def median_over_tolerance(histogram: list[int], tolerance: int) -> int | None:
    """The median worst-channel delta among the pixels that count as changed.

    Over the pixels PAST the tolerance rather than over the frame, because the
    canvas is almost entirely unchanged and a median over all of it is zero
    however far the changed pixels moved.

    None when nothing is past the tolerance, which is not a median of zero: no
    pixel changed at all, and a caller reading the two as the same would take a
    frame that did not move for one that moved by a rounding (L11).
    """
    over = [(value, count) for value, count in enumerate(histogram)
            if value > tolerance and count]
    counted = sum(count for _, count in over)
    if not counted:
        return None
    seen = 0
    for value, count in over:
        seen += count
        if seen * 2 >= counted:
            return value
    return over[-1][0]


def line(name: str, changed: int, total: int,
         box: tuple[int, int, int, int] | None = None,
         median_delta: int | None = None) -> str:
    """One reading, as it is written.

    Carries the raw count as well as the share. The share is what the threshold
    is compared against and the count is what it was derived from, and a record
    of shares alone could not be re-derived if the canvas size ever changed
    (L192).

    And it carries where the pixels are (#793). The comparison already builds
    the mask, so the box costs nothing to take, and without it every reading is
    a number with no way to ask what produced it.

    And how FAR they moved (#818). A count and a box cannot tell a render that
    moved by codec fidelity from one that moved by design: both can be the same
    number of pixels in the same place, and what separates them is amplitude,
    which nothing was writing down. The median is taken over the pixels past the
    tolerance, so it describes the ones that count as changed rather than being
    dragged to zero by the whole unchanged canvas.
    """
    # A markdown bullet, because a step summary renders what it is given and
    # consecutive plain lines are run together into one paragraph. A plain text
    # reader loses nothing by it.
    amplitude = "" if median_delta is None else f", median delta {median_delta}"
    return (f"- {name}: {changed} of {total} px, {changed / total:.4%}, "
            f"{where_they_are(box, changed)}{amplitude}")


@dataclass(frozen=True)
class Reading:
    """One reading, read back off the log (#818).

    `median_delta` is None for a line taken before amplitude was written down.
    None rather than 0, because a reading that never measured it and one where
    nothing differed by much are different states and only one of them can be
    reasoned about (L11).
    """

    name: str
    changed: int
    total: int
    box: tuple[int, int, int, int] | None
    median_delta: int | None

    @property
    def share(self) -> float:
        """Of the canvas, which is what MAX_CHANGED_FRACTION is compared against."""
        return self.changed / self.total

    @property
    def box_area(self) -> int:
        if self.box is None:
            return 0
        left, top, right, bottom = self.box
        return (right - left) * (bottom - top)

    @property
    def fill(self) -> float:
        """How much of its own box the change fills.

        A moved element leaves ink through its box; codec noise is scattered
        dust inside whatever rectangle happens to hold it.
        """
        return self.changed / self.box_area if self.box_area else 0.0

    @property
    def box_share(self) -> float:
        """How much of the canvas the box covers."""
        return self.box_area / self.total if self.total else 0.0


#: A reading as `line` writes it, read back.
#:
#: The one format, parsed by the module that writes it, so the two cannot drift
#: apart (L41). `tools/record_codec_change.py` reads the readings a run
#: published rather than re-deriving them, because the numbers it judges have to
#: be the numbers the comparison actually took.
_READING = re.compile(
    r"^- (?P<name>[^:]+): (?P<changed>\d+) of (?P<total>\d+) px, [0-9.]+%, "
    r"(?:no changed region|region (?P<width>\d+)x(?P<height>\d+) at "
    r"\((?P<left>\d+),(?P<top>\d+)\)(?:, [0-9.]+% of it)?)"
    r"(?:, median delta (?P<median>\d+))?$")


def parse(written: str) -> Reading | None:
    """One written line read back, or None if it is not a reading.

    None rather than a Reading of zeros: a log carries whatever else was
    appended to it, and a line nobody recognises has to be skipped rather than
    counted as a template that did not move (L11).
    """
    found = _READING.match(written.strip())
    if found is None:
        return None
    box = None
    if found.group("width") is not None:
        left, top = int(found.group("left")), int(found.group("top"))
        box = (left, top, left + int(found.group("width")),
               top + int(found.group("height")))
    median = found.group("median")
    return Reading(name=found.group("name"), changed=int(found.group("changed")),
                   total=int(found.group("total")), box=box,
                   median_delta=None if median is None else int(median))


def readings(log: Path) -> list[Reading]:
    """Every reading a run wrote, in the order it wrote them."""
    if not log.is_file():
        return []
    return [reading for reading in
            (parse(written) for written in log.read_text(encoding="utf-8").splitlines())
            if reading is not None]


def report(name: str, changed: int, total: int, *,
           box: tuple[int, int, int, int] | None = None,
           median_delta: int | None = None,
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
    written = line(name, changed, total, box, median_delta)
    where = destination(environment)
    if where is None:
        return None
    with where.open("a", encoding="utf-8") as handle:
        handle.write(written + "\n")
    return written


# ── a render that moved without the design moving (#818) ─────────────────────
#
# The fingerprint guard offers two outcomes when a template's source moves: it
# renders differently, so bump the design version, or it renders identically, so
# record the fingerprint alone. #811 was neither. Dropping `-preset veryfast`
# from the clip reel's last encode moved 0.27% of its pixels, which fails the
# reference frame, while the two frames are indistinguishable side by side.
#
# The version bump was the only door left, and a bump tells the app every cached
# asset of that template is out of date, which is a false alarm for a change
# nobody can see (L36). So there is a third outcome, and this is the evidence it
# rests on.
#
# EVERY number below was measured on this Mac on 2026-08-22, by rendering the
# template and diffing against its committed reference frame. They are recorded
# in `MEASURED_SHAPES` and each one is held to its verdict by
# `tests/test_codec_fidelity.py`, so a threshold that stops separating them is a
# failure rather than a stale comment.

#: The most a codec difference moves a pixel, as the median over the pixels past
#: the tolerance.
#:
#: The geometric middle of 9, the worst median a codec change produced, and 65,
#: the smallest median a MOVED element produced. Eight times under the smallest
#: real move and two and a half times over the noisiest encode.
#:
#: What this separates is a moved element, which replaces one colour with
#: another and reads in the hundreds. It cannot separate an element RECOLOURED
#: in place: the story's caption type drawn 8 lighter reads a median of 8, which
#: is what an encoder does. That case is what the two below are for.
CODEC_MEDIAN_DELTA = 24

#: The most of its own box a codec difference fills.
#:
#: The geometric middle of 2.33%, the fullest box a codec change produced, and
#: 7.91%, the emptiest a design change produced. Codec noise is dust inside
#: whatever rectangle happens to hold it; a design change leaves ink through
#: its box, whether it moved or was redrawn in place.
CODEC_MAX_FILL = 0.043

#: Neither condition is decoration, and each has a reading only IT refuses.
#:
#: Amplitude is the one that catches two elements a screen apart each moving a
#: pixel: the box is stretched between them and the fill collapses to 0.83%,
#: under what an encoder reads, while the pixels themselves have moved by 61.
#: Fill is the one that catches type recoloured in place, which reads a median
#: of 8, which is what an encoder reads.
#:
#: `test_each_threshold_is_the_only_thing_refusing_some_reading` holds that,
#: because a condition nothing in the table needs is one nobody can say is
#: calibrated, and it goes on reading as protection (L182). A third condition,
#: on how much of the canvas the box covers, was measured and dropped for
#: failing exactly this.

#: What this pair CANNOT separate, said out loud rather than left to be found.
#:
#: A change that is low amplitude AND sparse in its own box AND local to one
#: element reads exactly like an encoder rounding, and one label's antialiasing
#: moving is precisely that shape. A third condition on how much of the canvas
#: the box covers was measured and dropped: every design reading below is
#: refused by amplitude or fill before it is reached, so nothing calibrates it,
#: and a real codec difference contradicts it outright, since the 26 pixels #811
#: diagnosed sat in a 363x17 band, 0.3% of the canvas (L182).
#:
#: What covers it instead is the step that cannot be automated away: the third
#: door re-records reference frames and hands them back to be LOOKED at, the
#: same rule `POSTROLL_UPDATE_GOLDENS` has carried since the beginning.

#: What each measured perturbation read, and what it is.
#:
#: Taken by rendering, never by painting pixels into a synthetic frame, because
#: the thresholds have to separate what real templates do (L48). The two codec
#: readings are the clip reel's own reference frame; the design readings are the
#: story's, which renders to a PNG and carries no codec at all, so its numbers
#: are the design change on its own.
MEASURED_SHAPES: tuple[tuple[str, bool, int, int, tuple[int, int, int, int], int], ...] = (
    # what was changed, is it codec fidelity, changed, total, box, median delta
    ("clip reel, -preset veryfast back on the title pass (#811)",
     True, 5626, 2073600, (0, 129, 808, 428), 9),
    ("clip reel, -preset veryfast off the intermediate passes (#819)",
     True, 7189, 2073600, (0, 127, 1080, 1903), 7),
    ("story, second caption line moved one pixel",
     False, 1871, 2073600, (344, 1595, 736, 1624), 73),
    ("story, whole caption block moved one pixel",
     False, 3561, 2073600, (344, 1539, 736, 1624), 74),
    ("story, wordmark moved one pixel",
     False, 4624, 2073600, (266, 1654, 814, 1744), 65),
    ("story, wordmark moved four pixels",
     False, 7734, 2073600, (266, 1651, 814, 1744), 155),
    ("story, caption and wordmark each moved one pixel",
     False, 8185, 2073600, (266, 1539, 814, 1744), 68),
    ("story, title and wordmark each moved one pixel",
     False, 11078, 2073600, (50, 378, 1031, 1744), 61),
    ("story, caption type drawn 8 lighter",
     False, 2592, 2073600, (345, 1539, 735, 1623), 8),
    ("story, caption type drawn 20 lighter",
     False, 3678, 2073600, (345, 1539, 736, 1623), 20),
)


def why_it_is_not_codec_fidelity(reading: Reading) -> str | None:
    """Why this reading is a design change, or None if it is codec fidelity.

    A reason rather than a boolean, because the caller refuses with it and a
    refusal that cannot say which condition failed sends nobody anywhere (L11).

    Both conditions have to hold. A design change has to be low amplitude AND
    sparse in its own box before it is waved through, and a codec change that
    fails either is refused rather than assumed.
    Refusing wrongly costs a design version bump, which is what happens today;
    accepting wrongly hides a redesign behind a re-recorded frame, which is the
    thing the fingerprint guard exists to prevent.
    """
    if reading.box is None:
        return ("nothing changed in this frame at all, so there is no shape to "
                "read and nothing to re-record")
    if reading.median_delta is None:
        return ("the reading carries no amplitude, so nothing here can say how "
                "far these pixels moved. It was taken before #818 wrote that "
                "down, or by something other than the reference frames")
    if reading.median_delta > CODEC_MEDIAN_DELTA:
        return (f"the changed pixels moved by {reading.median_delta} on their "
                f"worst channel at the median, over the {CODEC_MEDIAN_DELTA} a "
                f"codec difference reads. An encoder rounds; a moved element "
                f"replaces one colour with another and reads in the hundreds")
    if reading.fill > CODEC_MAX_FILL:
        return (f"the change fills {reading.fill:.2%} of its own box, over the "
                f"{CODEC_MAX_FILL:.2%} a codec difference reads. Codec noise is "
                f"dust inside its rectangle; this leaves ink through it, which "
                f"is an element redrawn rather than an encoder rounding")
    return None
