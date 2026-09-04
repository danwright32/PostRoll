"""
PostRoll: lightweight Instagram grid cover image regeneration, standalone
from generate_media.py's full per-day pipeline (Phase 3, #141).

A "Regenerate cover" click or a manual "choose a different photo/frame"
override must never force a full day regen: for Friday that would mean
re-cutting the whole clip reel (a fresh Claude Stage 1/2 call plus an
ffmpeg render) just to refresh one thumbnail. This module is the cheap
path instead:

- override: render cover.png directly from a user-chosen source path, no
  Claude call at all.
- regenerate: pick fresh via Claude. Thursday's candidates are the day's
  own photos; Friday's are frames re-extracted from the day's already-
  PERSISTED clips_plan, never a fresh clip re-cut (mirrors
  generate_week.py's own _extract_clip_plan_frames: Stage 2's own
  representative frames live in a TemporaryDirectory long gone by the time
  this runs, so re-extraction from the persisted plan is the only option
  anyway, and it's the same one generate_media.py's full-day path uses).

Usage:
    from postroll.ai.generate_cover import generate_cover

    result = generate_cover(
        day_name="friday", day_info=manifest["days"]["friday"],
        event=..., org=..., venue=..., output_path="/path/to/cover.png",
    )
    # result == {"cover": "/path/to/cover.png",
    #            "cover_pick": {"source_path": ..., "rationale": ...}}
    # (no "cover_pick" key when override_source was given)
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from ..media.generate_story import generate_story
from .select_cover_photo import (
    select_cover_photo,
    _cover_candidates_from_friday_plan,
)


# The same owner generate_media reads it through (#334). This module used to
# declare its own copy of the path and its own "or no mark at all" fallback.
from ..media.wordmark import BLACK as LOGO_BLACK, required as required_wordmark  # noqa: E402


def generate_cover(
    *,
    day_name: str,
    day_info: dict[str, Any],
    event: str,
    org: str,
    venue: str,
    output_path: str,
    override_source: str | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {}

    # Named, and BEFORE the override branch (#961). Thursday no longer has a
    # cover at all, and every Thursday generated before that still carries a
    # cover_source in events.json, so the override path is exactly the one a
    # stale caller reaches. Falling through it would write a story composite
    # into a day whose export is not supposed to have one, quietly and
    # successfully.
    if day_name == "thursday":
        raise ValueError(
            "thursday has no cover: the slot was removed in #961 and Instagram "
            "picks its own grid thumbnail from a frame of the reel")

    if override_source:
        source_path = override_source
    elif day_name == "friday":
        selections = ((day_info.get("clips_plan") or {}).get("selections")) or []
        if not selections:
            raise ValueError("no persisted clips_plan to build cover candidates from")
        with tempfile.TemporaryDirectory(prefix="postroll-coverregen-") as tmp:
            candidates = _cover_candidates_from_friday_plan(selections, Path(tmp))
            if not candidates:
                raise ValueError("no frames could be extracted from the persisted clips_plan")
            pick = select_cover_photo(candidates)
            # The winning frame lives in `tmp`, gone the moment this block
            # exits; persist it next to cover.png so a later sticky-gate
            # regen (cover_source) can still find it.
            frame_dest = Path(output_path).parent / "cover_frame.jpg"
            shutil.copy2(pick["path"], frame_dest)
            source_path = str(frame_dest)
        result["cover_pick"] = {"source_path": source_path, "rationale": pick["rationale"]}
    else:
        raise ValueError(f"cover regeneration is not supported for day {day_name!r}")

    generate_story(
        photo_path=source_path,
        event_name=event,
        org=org,
        venue=venue,
        output_path=output_path,
        logo_path=required_wordmark(LOGO_BLACK),
    )
    result["cover"] = output_path
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Regenerate just the Instagram grid cover image for one day")
    parser.add_argument("--manifest", required=True, help="JSON manifest: day, event, org, venue, day_info, output_path, override_source")
    parser.add_argument("--output", required=True, help="Where to write the result JSON")
    args = parser.parse_args()

    m = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    try:
        result = generate_cover(
            day_name=m["day"],
            day_info=m.get("day_info", {}),
            event=m["event"],
            org=m["org"],
            venue=m["venue"],
            output_path=m["output_path"],
            override_source=m.get("override_source"),
        )
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
