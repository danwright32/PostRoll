#!/usr/bin/env python3
"""What the stored final body differs from the generated one by (#1128, Phase 0e).

The plan for the repair pass asked "how much does a REVISION rewrite the alt
text it was told to preserve". That is unmeasurable from what this app stores:
each event's `weekResult.blog` holds `{title, body, photo_count,
generated_body, findings, findings_body}` and there is no revision history
anywhere in `events.json`. The only available pair is `generated_body` against
`body`, which mixes a revision with Dan's own hand edits and cannot separate
them, which is the shape L216 and L107 warn about.

So this measures the pair that DOES exist and says which question it answers.
It is a tool rather than a number written into a comment, because a number with
a date on it reads as more trustworthy the older it gets, and this one moves
every time Dan finishes a post (L316, L61, L244).

    venv/bin/python tools/measure_blog_marker_drift.py

Reading on 2026-08-31, over the 21 stored events: 20 carry both bodies, 136
markers are shared by folded filename, 41 of them (30%) differ in alt text, and
8 of the 20 show a changed relative marker order.

That measurement decides nothing. The reason the revise path carries a verbatim
splice is the code reading alone: `revise_blog` sends its pass 1 call with no
validator, and `markers_preserved_validator` sorts and never reads alt text.
That is structural and does not need a rate to justify it.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from postroll.ai.blog_quality import _fold_filename, _markers  # noqa: E402
from postroll.data_root import data_root  # noqa: E402


def measure(events: list[dict]) -> dict[str, int]:
    """Counted here rather than in the printer, so a test can assert on it."""
    out = {"events": len(events), "with_both_bodies": 0, "shared_markers": 0,
           "alt_text_differs": 0, "order_changed": 0}
    for event in events:
        blog = (event.get("weekResult") or {}).get("blog") or {}
        generated, final = blog.get("generated_body"), blog.get("body")
        if not generated or not final:
            continue
        out["with_both_bodies"] += 1
        was = [(_fold_filename(n), a.strip()) for n, a in _markers(generated)]
        now = [(_fold_filename(n), a.strip()) for n, a in _markers(final)]
        was_by, now_by = dict(was), dict(now)
        shared = [key for key, _ in was if key in now_by]
        out["shared_markers"] += len(shared)
        out["alt_text_differs"] += sum(1 for k in shared if was_by[k] != now_by[k])
        # Compared over the markers the two bodies SHARE, so a photo swapped in
        # or out is not counted as a reorder.
        if shared != [key for key, _ in now if key in was_by]:
            out["order_changed"] += 1
    return out


def main() -> int:
    path = Path(data_root()) / "events.json"
    if not path.exists():
        # An absent store is not an empty one, and reporting zeros for it would
        # read as a measurement (L98).
        print(f"no stored events at {path}, so there is nothing to measure",
              file=sys.stderr)
        return 1
    counts = measure(json.loads(path.read_text(encoding="utf-8")))
    shared = counts["shared_markers"]
    share = f"{counts['alt_text_differs'] / shared:.0%}" if shared else "n/a"
    print(f"{counts['events']} stored events, {counts['with_both_bodies']} carrying "
          f"both a generated and a final body")
    print(f"{shared} markers shared by folded filename, "
          f"{counts['alt_text_differs']} of them ({share}) differ in alt text")
    print(f"{counts['order_changed']} of {counts['with_both_bodies']} show a "
          f"changed relative marker order")
    print("this is the final body against the generated one, which mixes a "
          "revision with Dan's own hand edits; it is not a revision drift rate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
