"""Re-take the reading #1067's case was built on (#1219).

#1067 measured the live store once: of 21 events with a Thursday caption, 12
alt texts described a single moment rather than the reel, and 7 were under the
25 word floor the scroll reel instruction itself sets. Four fixes shipped, and
every test written for them drives a stubbed model, so they prove the machinery
does what it says and say nothing about what the real model now produces (L3,
L56).

    venv/bin/python tools/measure_thursday_alt_text.py [--store PATH]

Prints COUNTS and never an alt text. A privacy guard that scans the repository
cannot see what a tool prints, so a reading over a live system otherwise
delivers real performer names into a transcript by a route nothing inspects
(L222).

## The two counts

A reel takes ONE alt text describing the whole reel, so more than one is the
model having written one per photograph. That states #1067's "single moment"
fault as a SHAPE rather than as a judgement about language, so nothing here
reads the prose to decide.

The word floor and the post type both come from the app's own predicates rather
than being written out again: `generate_captions._alt_word_floor` parses the
range the instruction actually states, and `posting_preset.post_type` decides
what a day is. An ad hoc reimplementation beside the code is a second
definition that drifts towards whatever flatters the argument (L107).

Neither the post type nor the preset is stored on an event, so `DEFAULT_PRESET`
is the honest fallback.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.ai.generate_captions import _alt_word_floor  # noqa: E402
from postroll.posting_preset import DEFAULT_PRESET, post_type  # noqa: E402

#: Where the app keeps it.
LIVE_STORE = (Path.home() / "Library" / "Application Support" / "PostRoll"
              / "events.json")

#: What #1067 measured, and what of it this tool can actually reproduce.
#:
#: Only the word floor. "12 alt texts described a single moment rather than the
#: reel" was a judgement about the PROSE of individual alt texts, made by
#: reading them; nothing here reads prose, so there is no honest way to compare
#: a count against it. Printing one beside the other would invite exactly the
#: comparison that cannot be made, and a number presented beside a baseline is
#: read as being in the same units whatever the words around it say (L118).
#:
#: So the shape count below is a NEW measure with its own first reading, and it
#: says so.
BASELINE = {"events": 21, "under_floor": 7, "measured_on": "2026-08-27"}

#: The shape reading taken when this tool was written, over the same 21 events,
#: so the next run has something in its OWN units to compare against.
SHAPE_BASELINE = {"reels": 21, "per_frame": 1, "measured_on": "2026-09-04"}

#: The day this is about. #1067 is specifically the Thursday scroll reel.
DAY = "thursday"


@dataclass(frozen=True)
class Reading:
    events: int
    reels: int
    alt_texts: int
    per_frame: int
    under_floor: int
    #: The same fault counted per REEL as well as per alt text, because
    #: #1067's baseline is "7 of 21" and a rate compared against a different
    #: denominator is not a comparison at all (L118).
    events_under_floor: int


def read_store(path: Path) -> Reading:
    """Count the two faults over every event in `path`."""
    events = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(events, dict):
        events = events.get("events", [])
    if not events:
        # Zero of everything is what a wrong key produces and is
        # indistinguishable from a store in which every alt text is correct
        # (L98). A first pass over this store read `program` instead of
        # `ocrResult` and reported a rule as never firing.
        raise SystemExit(
            f"{path} holds no events, so every count below would be zero and "
            "that reads exactly like a store with nothing wrong in it. "
            "Nothing was measured.")

    reels = alt_texts = per_frame = under_floor = events_under_floor = 0
    for event in events:
        day = (event.get("weekResult") or {}).get(DAY) or {}
        alts = day.get("alt_texts") or []
        if not alts:
            continue
        assigned = len(((event.get("days") or {}).get(DAY) or {})
                       .get("photoPaths") or [])
        kind = post_type(DEFAULT_PRESET, DAY, assigned)
        floor = _alt_word_floor(kind)
        if floor is None or "reel" not in kind:
            continue
        reels += 1
        alt_texts += len(alts)
        if len(alts) > 1:
            per_frame += 1
        short = sum(1 for alt in alts if len(str(alt).split()) < floor)
        under_floor += short
        events_under_floor += 1 if short else 0
    return Reading(events=len(events), reels=reels, alt_texts=alt_texts,
                   per_frame=per_frame, under_floor=under_floor,
                   events_under_floor=events_under_floor)


def render(reading: Reading) -> str:
    """The reading, as counts, beside what it is being compared against."""
    def rate(n: int, of: int) -> str:
        return f"{n} of {of}" + (f" ({n / of * 100:.0f}%)" if of else "")

    return "\n".join([
        f"events in the store: {reading.events}",
        f"with a {DAY} reel caption: {reading.reels}, "
        f"holding {reading.alt_texts} alt texts",
        "",
        "SHAPE, a reel given more than one alt text instead of one describing "
        "the whole reel:",
        f"  {rate(reading.per_frame, reading.reels)}"
        f"   first taken {SHAPE_BASELINE['per_frame']} of "
        f"{SHAPE_BASELINE['reels']} on {SHAPE_BASELINE['measured_on']}",
        "",
        "LENGTH, alt texts under the floor their own instruction states:",
        f"  {rate(reading.under_floor, reading.alt_texts)} alt texts, "
        f"{rate(reading.events_under_floor, reading.reels)} reels"
        f"   baseline {BASELINE['under_floor']} of {BASELINE['events']} "
        f"on {BASELINE['measured_on']}",
        "",
        "NOT comparable to #1067's other figure. Its '12 of 21 described a",
        "single moment rather than the reel' was a judgement about the PROSE of",
        "individual alt texts. Nothing here reads prose, so the shape count",
        "above is a different measure and carries its own first reading rather",
        "than being set beside a number in other units (L118).",
        "",
        "And an unchanged store is the same reading, not a confirmation that",
        "anything improved: nothing stamps when an alt text was written, so",
        "these move only when a week is GENERATED again.",
    ])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--store", type=Path, default=LIVE_STORE)
    args = parser.parse_args(argv)
    if not args.store.exists():
        raise SystemExit(f"no store at {args.store}. Nothing was measured.")
    print(render(read_store(args.store)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
