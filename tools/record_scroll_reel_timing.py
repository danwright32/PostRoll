"""Record the Thursday reel's timing contract (#1076).

The app has to answer two questions before anything is rendered: how long the
reel will be, so it can say whether the chosen track covers it, and how fast it
will scroll, so it can say whether that is comfortable to watch. Both are
functions of constants that live in `postroll/media/generate_reel_scroll.py`,
and both are asked on the Swift side, where nothing forces the two to agree.

That is the split that put an 8px gutter in the collage editor against Python's
16 (#969). So the numbers are stated once here, both sides assert against them,
and whichever half stops matching fails.

Run it when the reel's timing, frame rate, viewport or easing changes.

    venv/bin/python tools/record_scroll_reel_timing.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.media import generate_reel_scroll as scroll  # noqa: E402
from postroll.media.easing import cruise_factor  # noqa: E402

FIXTURE = REPO_ROOT / "tests" / "fixtures" / "scroll_reel_timing.json"

#: What the editor's slider offers, from PhotoAssignmentView. Recorded here so
#: the reel lengths below span the range a person can actually ask for.
SLIDER_MIN_S = 15.0
SLIDER_MAX_S = 60.0
SLIDER_STEP_S = 5.0


def build() -> dict:
    scroll_seconds = []
    current = SLIDER_MIN_S
    while current <= SLIDER_MAX_S:
        scroll_seconds.append(current)
        current += SLIDER_STEP_S

    return {
        "_comment": (
            "Written by tools/record_scroll_reel_timing.py. The Thursday reel's "
            "timing, stated once for both languages: Python renders with these "
            "and the Swift editor answers 'is the music long enough' and 'is "
            "this comfortable to watch' from the same numbers, before anything "
            "is rendered."),

        # Reel length. A reel is the scroll the person chose plus a hold at the
        # bottom and the closing frame, so a track that covers the SCROLL can
        # still be six seconds short of the reel.
        "hold_end_s": scroll.HOLD_END,
        "closing_frame_s": scroll.CLOSING_FRAME_DURATION,
        "slider": {"min_s": SLIDER_MIN_S, "max_s": SLIDER_MAX_S,
                   "step_s": SLIDER_STEP_S},
        "reel_seconds_for_scroll": {
            f"{seconds:g}": seconds + scroll.HOLD_END + scroll.CLOSING_FRAME_DURATION
            for seconds in scroll_seconds
        },

        # Scroll speed. The viewport is what a viewer sees at once, and the
        # cruise factor turns the average speed into the speed they actually
        # watch, since the ends are ramps.
        "fps": scroll.FPS,
        "viewport_h": scroll.VIEWPORT_H,
        "ease_ramp": scroll.EASE_RAMP,
        "cruise_factor": cruise_factor(scroll.EASE_RAMP),
    }


def main() -> int:
    FIXTURE.write_text(json.dumps(build(), indent=2) + "\n", encoding="utf-8")
    doc = json.loads(FIXTURE.read_text(encoding="utf-8"))
    shortest = min(doc["reel_seconds_for_scroll"], key=float)
    longest = max(doc["reel_seconds_for_scroll"], key=float)
    print(f"recorded {FIXTURE.relative_to(REPO_ROOT)}: "
          f"a {shortest}s scroll is a "
          f"{doc['reel_seconds_for_scroll'][shortest]:g}s reel and a {longest}s "
          f"scroll is a {doc['reel_seconds_for_scroll'][longest]:g}s one, "
          f"{doc['fps']}fps, viewport {doc['viewport_h']}px, "
          f"cruise {doc['cruise_factor']:.2f}x")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
