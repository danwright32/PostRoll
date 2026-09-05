#!/usr/bin/env python3
"""Time one real alt-text repair call, with a photograph attached (#1127).

Dan's decision, 2026-08-31: spend one real image-carrying call, record the
number with its date, and derive the repair pass's per-call timeout and its
round budget from it.

**No image-carrying call has ever been timed in this project.** The plan's 300
seconds is cloned from `swap_blog_photos.py`, which is the only image-carrying
call in the repo, and its 300 was itself never measured. At that figure seven
markers at two rounds is 4,200 seconds against an 1,800 second process ceiling,
so the round cap would have to drop to one round per target and the repair would
be weaker for a number nobody measured (L501, L102).

The cheaper-looking alternative was worse. `generate_blog.py` makes text-only
`run_prompt` calls at `timeout=120`, one paragraph in and one out, and cloning
that constant has a specific compounding harm: an image call that legitimately
needs more than 120 seconds times out, is marked `blocked`, and Dan is told the
app could not reach the model on a rewrite it did in fact start, which is the
claim L11 forbids.

This is a TOOL and not a test. It costs money and reaches the live API, which is
exactly what the suite may never do (L2). Run it deliberately:

    venv/bin/python tools/measure_alt_text_call.py --photo /path/to/a.jpg

It writes the reading to `tests/fixtures/alt_text_call_timing.json`, which is
what the repair pass derives its timeout from, so the number has a writer, a
date, a command and a re-run path rather than being a sentence in a comment
(L316). Repeat runs append: one reading is a sample of one, and the constants
should be re-derived once there are three.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORD = REPO_ROOT / "tests" / "fixtures" / "alt_text_call_timing.json"

#: How many calls one reading is. Each `--photo` run times exactly one, so 1 is
#: the honest answer, and `runs: 1` is a fine one: what matters is that a reader
#: can tell a single reading from a median of six (#1328).
RUNS_PER_READING = 1

#: Said by the tool that writes the record, because a hand edit here is lost.
#:
#: The count of `readings` is deliberately NOT offered as the sample size: the
#: three recorded are three different photographs rather than three readings of
#: one call, and a list's length standing in for a sample reports a number of
#: the wrong thing, which is worse than reporting none (L11).
SAMPLE_NOTE = ("Each reading is one call, so runs is 1 on every one of them. "
               "The readings are different photographs rather than repeated "
               "readings of one, so their count is not a sample size (#1328).")

#: The prompt shape the repairer sends: one photograph, one marker, every
#: finding for it, the venue, the performer names and the word band. Measured
#: with the real shape rather than a stub, because what is being timed is an
#: image-carrying call and a text-only one is a different measurement (L102).
PROMPT = """\
Rewrite the alt text for ONE photograph, attached. Return JSON only.

The current alt text is:
{alt}

It breaks these rules and must stop breaking them:
{findings}

Rules for the replacement:
- {min_words} to {max_words} words.
- Name the venue: {venue}.
- Name the performer. The people on this bill are: {performers}.
- Describe what the camera recorded. No inferred inner states, nothing about
  what somebody felt or who an expression was aimed at.
- Name people by name, never by appearance or gender.
- Keep describing the same photograph. Do not drop what it shows.

Return JSON ONLY:
{{"alt": "<the replacement>"}}"""


def measure(photo: Path, *, timeout: int) -> dict:
    """One real call, timed. Returns the reading."""
    from postroll.ai.claude_client import run_json_prompt

    prompt = PROMPT.format(
        alt="A male performer in a grey t-shirt stands on a raised platform "
            "with one arm raised, holding a microphone",
        findings="- alt_text_appearance_descriptor: names an appearance rather "
                 "than a person\n- alt_text_missing_venue: does not name the venue",
        min_words=15, max_words=25,
        venue="The Green Room 42",
        performers="Kate DiGangi, Ryan Cavanagh",
    )

    started = time.monotonic()
    answer = run_json_prompt(prompt, timeout=timeout, image_paths=[str(photo)],
                             image_labels=[photo.name],
                             step="measure_alt_text_call")
    elapsed = time.monotonic() - started

    return {
        "measured_on": date.today().isoformat(),
        "seconds": round(elapsed, 1),
        "photo_bytes": photo.stat().st_size,
        "answered": bool(isinstance(answer, dict) and answer.get("alt")),
        "words": len(str((answer or {}).get("alt", "")).split()),
        # One call, timed once. Built with the reading rather than added to the
        # file afterwards: this tool APPENDS, so a hand edit covers the readings
        # already there and never the next one (L379, #1328).
        "runs": RUNS_PER_READING,
    }


def load() -> list[dict]:
    if not RECORD.exists():
        return []
    return json.loads(RECORD.read_text(encoding="utf-8")).get("readings", [])


#: The floor under any recommended timeout, however fast the calls measure.
#:
#: The harm is ASYMMETRIC and that is the whole reason this is not just a
#: multiple of the slowest reading. A timeout set too LOW cuts a call that DID
#: start and reports it as `blocked`, telling Dan the app could not reach the
#: model on a rewrite it had in fact begun, which is the claim L11 forbids. A
#: timeout set too HIGH costs only that a genuinely dead call is noticed later,
#: and the pass has a wall clock deadline that stops it overrunning regardless.
#:
#: These readings are also a sample of three, on one machine, on one network, on
#: one day. Three times the slowest of them is nine seconds, and a threshold
#: that tight would turn any slow morning into a panel full of "the app could
#: not reach the model". So the recommendation never goes below this, and the
#: real protection against a pass that runs long is the deadline, not this.
_TIMEOUT_FLOOR = 120


def summarise(readings: list[dict]) -> dict:
    """What the constants are derived from.

    Only readings that ANSWERED count toward the cost. A call that returned
    nothing timed the failure, not the work, and averaging it in would report a
    broken run as a fast one (L98, L331).
    """
    seconds = sorted(r["seconds"] for r in readings if r.get("answered"))
    if not seconds:
        return {}
    slowest = seconds[-1]
    return {
        "readings": len(seconds),
        "fastest": seconds[0],
        "median": statistics.median(seconds),
        "slowest": slowest,
        "recommended_timeout": max(_TIMEOUT_FLOOR,
                                   int(-(-slowest * 3 // 30) * 30)),
        # What the round budget actually costs at the measured rate. The plan
        # assumed 300 seconds a call and concluded the round cap would have to
        # drop to one; measured, seven markers at two rounds is under a minute.
        "seven_markers_two_rounds": round(slowest * 14, 1),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--photo", type=Path,
                        help="A real photograph to attach. Required to measure.")
    parser.add_argument("--timeout", type=int, default=600,
                        help="Ceiling for THIS measurement, deliberately generous: "
                             "a timeout here would measure the ceiling, not the call")
    parser.add_argument("--show", action="store_true",
                        help="Print the existing record without spending anything")
    args = parser.parse_args()

    readings = load()

    if args.show or not args.photo:
        if not readings:
            # An empty record is not a fast call (L98).
            print("no readings recorded yet, so nothing here has been measured. "
                  "Run with --photo <a real photograph> to take one.",
                  file=sys.stderr)
            return 1
        print(json.dumps({"readings": readings, "summary": summarise(readings)},
                         indent=2))
        return 0

    if not args.photo.exists():
        print(f"no photograph at {args.photo}", file=sys.stderr)
        return 1

    print(f"spending ONE real image-carrying Claude call on {args.photo.name} "
          f"({args.photo.stat().st_size // 1024} KB)", file=sys.stderr)
    reading = measure(args.photo, timeout=args.timeout)

    if not reading["answered"]:
        # A call that returned nothing timed the failure, not the work (L98).
        print(f"the call returned no alt text after {reading['seconds']}s, so "
              f"this reading is of a FAILURE and is recorded as such rather "
              f"than as the cost of the work", file=sys.stderr)

    readings.append(reading)
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    RECORD.write_text(json.dumps({
        "_what": "How long one alt text repair call takes with a photograph "
                 "attached (#1127). Written by tools/measure_alt_text_call.py; "
                 "the repair pass derives its per-call timeout from the summary.",
        "_sample": SAMPLE_NOTE,
        "readings": readings,
    }, indent=2) + "\n", encoding="utf-8")

    print(json.dumps({"reading": reading, "summary": summarise(readings)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
