"""Record the shared collage gutter contract (#969).

`tests/fixtures/collage_gutter.json` states the gutter once for both languages
and carries real layouts to measure it in. The layouts come from
`plan_collage_cells` rather than being written by hand, because a hand made
layout is a shape somebody chose and would go on agreeing with a Swift editor
that had drifted from what Python actually draws (L48).

Run it when the gutter, the branded strip or the planner's arithmetic changes.
The tests on both sides then say whether each language agrees with the new
contract, which is the question, rather than with the old one.

    venv/bin/python tools/record_collage_gutter.py
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.media import generate_collage as collage  # noqa: E402
from postroll.media.design_tokens import GUTTER  # noqa: E402

FIXTURE = REPO_ROOT / "tests" / "fixtures" / "collage_gutter.json"

#: The floor a cell may not be dragged below, from `minCollageCellPx` in
#: PostRollApp/Sources/Views/CaptionReview/CollageDividers.swift. Stated in the
#: contract so the Swift side asserts its own constant against it rather than
#: against a number repeated in a test.
MIN_CELL_PX = 80

#: One layout per split shape the chooser can hand over, each with at least one
#: row of two so there is a vertical boundary to measure. The seed is recorded
#: with each so the layout can be reproduced exactly.
SPLITS = [
    ("two over two", [2], [2]),
    ("two over three", [2], [3]),
    ("three over three", [3], [3]),
    ("two and two over three", [2, 2], [3]),
]

#: A 3:2 landscape, which is what Dan shoots.
PHOTO_RATIO = 1.5
SEED = 7


def build() -> dict:
    cases = []
    for name, top, bottom in SPLITS:
        count = sum(top) + sum(bottom)
        cells, strip_y = collage.plan_collage_cells(
            [PHOTO_RATIO] * count, top, bottom, random.Random(SEED))
        cases.append({
            "name": name,
            "top_pattern": top,
            "bottom_pattern": bottom,
            "photo_ratio": PHOTO_RATIO,
            "seed": SEED,
            "strip_y": strip_y,
            "cells": [{"photo_path": f"/photos/{c['index']}.jpg",
                       "x": c["x"], "y": c["y"], "w": c["w"], "h": c["h"]}
                      for c in cells],
        })
    return {
        "_comment": (
            "Written by tools/record_collage_gutter.py. The gutter between "
            "collage tiles, stated once: Python bakes it into the base PNG and "
            "the Swift editor computes divider positions and drag clamps over "
            "the same layout. The cells are what plan_collage_cells draws."),
        "gutter_px": GUTTER,
        "strip_h_px": collage.STRIP_H,
        "min_cell_px": MIN_CELL_PX,
        "cases": cases,
    }


def main() -> int:
    FIXTURE.write_text(json.dumps(build(), indent=2) + "\n", encoding="utf-8")
    doc = json.loads(FIXTURE.read_text(encoding="utf-8"))
    print(f"recorded {FIXTURE.relative_to(REPO_ROOT)}: "
          f"gutter {doc['gutter_px']}px, strip {doc['strip_h_px']}px, "
          f"{len(doc['cases'])} layout(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
