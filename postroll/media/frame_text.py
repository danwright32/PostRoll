"""Does a rendered frame name the show it was generated for? (#754)

`frame_legibility` measures whether the ink in a declared region is THERE and
how far it is from what sits behind it. What nothing measured is whether the
words are the RIGHT words. A story generated for "The One-Man Odyssey" that
rendered a blank title, the previous day's title, or a truncated one passes
every check in this repo and reports a clean run.

That matters because of how #752 was found: the only detector was Dan seeing a
published post on his phone. The same is true of the two defects
`frame_legibility` was written for, both of which shipped and were caught by Dan
watching an encoded video. Every layer measures the frame's APPEARANCE; nothing
tied the frame back to the show it was generated for.

## How the words are read

Apple's Vision, through `tools/read_frame_text.swift`. It is on the machine
already, so it costs nothing, needs no Python dependency and no network, and it
reads SignPainter, the script face the titles are set in. The other OCR in this
repo, `postroll/ai/ocr_program.py`, goes to the metered Claude API, which a test
may not touch (L2).

## How a reading is judged

By CONTAINMENT of the whole expected name in what was read, with punctuation
and case folded away. Not by similarity, and this was measured rather than
preferred. Similarities on real renders, 2026-08-20, name "The One-Man Odyssey":

    story, collage, before/after, scroll reel header, all correct   1.000
    the title truncated to "The One-Man Odysse"                     0.968
    one character misread, "Odysscy"                                0.938
    the title truncated to "The One-Man Odyss"                      0.933
    the title truncated to "The One-Man Ody"                        0.857
    a different show rendered                                       0.296
    the title left blank                                            0.273

A truncated title and a misread character are the same edit distance, so no
similarity threshold can separate them: any bar low enough to forgive a misread
forgives a truncation of the same size. Containment refuses to guess. The whole
name is present or it is not.

That makes this deliberately strict, and the strictness is the safe direction:
a misread reports a real frame for a person to look at, while a threshold
generous enough to forgive one would wave through the defect the check exists
to catch. It is affordable because it was calibrated: across all four templates
in the real script face, every title read at exactly 1.000 with the name
contained outright. The one thing Vision did misread is the stylised wordmark,
"DN/DAN WRICHT", which is a logo rather than a title and is not what is asked
about here.

A name split over two readings, which is how a long title on two lines arrives,
is contained in the joined text and passes. The joined text is used for that
reason and no other: nothing is matched loosely against it, because a check over
a whole body of text is otherwise satisfied by unrelated places in it (L135),
and the joined frame really does contain scattered letters that flatter a
truncated title back up to passing.

## An empty answer is a failure

An OCR pass that reads NOTHING is not a pass. A blank region and a correctly
rendered one are the same answer to a naive "does it contain the title" check
when the reader could not see the frame at all (L98), so nothing-read is
reported in its own words, separately from read-but-wrong.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

#: The Vision helper. Named from this file's own location, so a checkout
#: anywhere finds it and nothing depends on the working directory.
READER = REPO_ROOT / "tools" / "read_frame_text.swift"

#: How long the reader is given. It is a local Vision call of well under a
#: second on a rendered frame; a minute is a deadline rather than a guess, and a
#: wait with no deadline cannot fail, it can only hang (L110).
TIMEOUT_SECONDS = 60


class ReaderUnavailable(RuntimeError):
    """The frame could not be read, which is not the same as reading nothing.

    Raised rather than returning an empty list, because the caller cannot tell
    those apart from the outside and the empty one is the answer that reads as
    reassurance.
    """


@dataclass(frozen=True)
class Reading:
    """One run of text Vision found, and how sure it was."""
    confidence: float
    text: str


def available() -> tuple[bool, str]:
    """Whether this machine can read a frame, and why not when it cannot.

    The reason travels with the answer so a caller skipping the check can say
    what it skipped for, rather than leaving a silent absence that reads exactly
    like a check that passed.
    """
    if not READER.is_file():
        return False, f"{READER} is missing"
    if shutil.which("swift") is None:
        return False, "swift is not on PATH, so the Vision reader cannot be run"
    return True, ""


def read_frame(image_path: str | Path,
               box: tuple[int, int, int, int] | None = None) -> list[Reading]:
    """Every run of text in a frame, or in one band of it.

    `box` is (left, top, right, bottom) in canvas pixels, the same currency
    `frame_legibility.TextRegion` uses, so a declared title band can be handed
    straight here.
    """
    ready, why = available()
    if not ready:
        raise ReaderUnavailable(why)

    command = ["swift", str(READER), str(image_path)]
    if box is not None:
        command += [str(int(value)) for value in box]

    try:
        finished = subprocess.run(command, capture_output=True, text=True,
                                  timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise ReaderUnavailable(
            f"the reader did not answer within {TIMEOUT_SECONDS}s for "
            f"{image_path}") from error

    if finished.returncode != 0:
        raise ReaderUnavailable(
            f"the reader exited {finished.returncode} for {image_path}: "
            f"{finished.stderr.strip() or 'it said nothing'}")

    readings = []
    for line in finished.stdout.splitlines():
        if "\t" not in line:
            continue
        confidence, text = line.split("\t", 1)
        readings.append(Reading(float(confidence), text))
    return readings


def normalised(text: str) -> str:
    """Letters and digits only, folded to lower case.

    The script face sets an apostrophe, a hyphen and a space in ways Vision
    reports inconsistently, and none of them is what is being asked about. What
    is being asked is whether the show's name is on the frame.
    """
    return re.sub(r"[^a-z0-9]", "", text.lower())


def names_the_show(readings: list[Reading], event_name: str) -> str | None:
    """Why this frame does not name this show, or None when it does.

    A sentence rather than a bool, because the three ways it fails need three
    different things done about them and a caller handed `False` cannot tell
    them apart (L11).
    """
    wanted = normalised(event_name)
    if not wanted:
        raise ValueError(
            "asked whether a frame names a show with no name, which no frame "
            "can answer either way")

    if not readings:
        return ("nothing at all could be read from this frame, so whether it "
                "names the show is unknown rather than answered. A frame with "
                "no words on it and a frame the reader could not see report "
                "the same way from here")

    joined = normalised(" ".join(reading.text for reading in readings))
    if wanted in joined:
        return None

    found = ", ".join(repr(reading.text) for reading in readings)
    return (f"this frame does not name {event_name!r}. Every word read from it "
            f"is here, and the show's name is not among them: {found}. A "
            "title that is blank, that names another show, or that lost part "
            "of itself all arrive this way, and so does a character Vision "
            "misread, so look at the frame rather than loosening the match")
