"""
PostRoll — Canonical Jamendo audio-tag defaults.

Single source of truth for the Jamendo search tags PostRoll uses to:
  1. Auto-pick background audio when the user hasn't chosen any (the reel
     generators fall back to these defaults when `audio_path is None`).
  2. Suggest tracks in the Swift app's manual track picker. The Swift side
     calls this module's CLI so the manual suggestions match what auto-fetch
     would have grabbed.

Used to live in two places — the reel generators (`_DEFAULT_AUDIO_TAGS`
constants) and the Swift `tuesdayAutoTags` / `thursdayAutoTags` properties —
which silently drifted out of sync. Centralized here.

Usage from Python:
    from postroll.ai.audio_tags import TUESDAY_DEFAULT_TAGS, derive_audio_tags

Usage from Swift (CLI mode):
    python -m postroll.ai.audio_tags --day thursday --shoot-type performance \\
        --program /tmp/program.json
    # prints: orchestral,classical
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


# Tuesday speed-edit reel — energetic, doesn't depend on program content.
TUESDAY_DEFAULT_TAGS = "electronic,upbeat"

# Thursday scroll reel — final fallback when shoot type and program text both
# fail to suggest anything more specific.
THURSDAY_FALLBACK_TAGS = "ambient,atmospheric"


_SACRED_CHORAL_KEYWORDS = (
    "gospel", "praise", "hymn", "church", "sacred", "amen", "hallelujah",
    "smallwood", "total praise", "african spiritual", "negro spiritual",
    "soon we will", "freedom song", "traditional spiritual",
    "requiem", "kyrie", "sanctus", "mass ", "motet", "anthem",
    "cantata", "gloria", "agnus dei", "pie jesu", "magnificat",
)
_JAZZ_KEYWORDS = (
    "jazz", "blues", "swing", "bebop", "coltrane", "ellington", "monk", "mingus",
)


def thursday_tags(shoot_type: str, pieces: list[dict[str, Any]]) -> str:
    """Pick Thursday scroll-reel tags based on the program's musical content.

    Tag combinations are restricted to the ones we've verified return enough
    Jamendo results:
      - "jazz" — jazz/blues programs
      - "inspirational,orchestral" — sacred/choral content in a concert setting
      - "orchestral,classical" — generic classical/orchestral programs
      - "ambient,atmospheric" — fallback (photo calls, light shoots, etc.)

    Note: Jamendo's "gospel" tag skews acoustic/slow guitar, which doesn't fit
    a concert orchestra performing a gospel piece — we pick "inspirational,
    orchestral" instead so the audio matches the visual setting.
    """
    text = " ".join(
        f"{p.get('title', '')} {p.get('composer', '')}" for p in pieces
    ).lower()
    if any(k in text for k in _JAZZ_KEYWORDS):
        return "jazz"
    if any(k in text for k in _SACRED_CHORAL_KEYWORDS):
        return "inspirational,orchestral"
    if shoot_type in ("performance", "rehearsal_and_performance"):
        return "orchestral,classical"
    return THURSDAY_FALLBACK_TAGS


def derive_audio_tags(
    day: str,
    shoot_type: str = "performance",
    pieces: list[dict[str, Any]] | None = None,
) -> str:
    """Return the canonical Jamendo tags for the given posting day.

    Args:
        day: One of "tuesday" / "thursday" (other days don't use audio).
        shoot_type: One of the values produced by ShootType.pythonValue.
        pieces: OCR pieces list (only Thursday reads this).
    """
    if day == "tuesday":
        return TUESDAY_DEFAULT_TAGS
    if day == "thursday":
        return thursday_tags(shoot_type, pieces or [])
    return THURSDAY_FALLBACK_TAGS


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Print the canonical Jamendo tags for a posting day"
    )
    parser.add_argument("--day", required=True,
                        choices=["tuesday", "thursday"],
                        help="Which posting day's tags to compute")
    parser.add_argument("--shoot-type", default="performance",
                        help="Event shoot_type (performance, photo_call, …)")
    parser.add_argument("--program", type=Path,
                        help="Path to OCR program JSON (used for Thursday)")
    parser.add_argument("--output", type=Path,
                        help="If set, write the tags string here instead of stdout")
    args = parser.parse_args()

    pieces: list[dict[str, Any]] = []
    if args.program and args.program.exists():
        try:
            data = json.loads(args.program.read_text(encoding="utf-8"))
            pieces = data.get("pieces", []) or []
        except (json.JSONDecodeError, OSError) as e:
            print(f"warning: failed to read {args.program}: {e}", file=sys.stderr)

    tags = derive_audio_tags(args.day, args.shoot_type, pieces)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(tags + "\n", encoding="utf-8")
    else:
        print(tags)
    return 0


if __name__ == "__main__":
    sys.exit(main())
