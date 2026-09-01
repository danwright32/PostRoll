"""Whether a saved collage layout can be rendered at all (#967, #970).

Every divider drag in the Thursday and Wednesday editors writes cell geometry
straight into the saved override, and `CollageRenderer.render` composites those
exact cells over the base PNG. So an impossible layout is not a preview
problem: it is what gets exported and what is written back to events.json.

#965 fixed the one drag known to produce one, where the boundary above the
branded strip could be dragged down until the row below it had a height of
minus two. This is the rule the SAVE has to satisfy, whatever produced it, so a
future editor inherits the refusal rather than having to remember it.

The rule and its cases live in `tests/fixtures/collage_layout_validity.json`,
asserted from both here and Swift, because the geometry is implemented twice
and nothing else forces the two to agree (L26).

The strip band is passed in rather than inferred here. Where it sits depends on
how many rows are above it, `render_cell_layout_override` already recovers it
from an override, and a validator that inferred it a second way would be a
second answer to the same question (L263).
"""

from __future__ import annotations

#: The smallest a cell may be on either axis, in canvas pixels.
#:
#: The same floor `computeCollageDividers` clamps a drag to. A layout saved
#: under it means a clamp was wrong or a path skipped one, which is exactly
#: what #965 was.
MIN_CELL_PX = 80

CANVAS_W = 1080
CANVAS_H = 1920


def layout_problems(
    cells: list[dict],
    *,
    strip_y: int | None = None,
    strip_h: int = 0,
    canvas: tuple[int, int] = (CANVAS_W, CANVAS_H),
) -> list[str]:
    """Every reason `cells` cannot be rendered, sorted, or an empty list.

    Codes rather than sentences, because both sides of the bridge and both
    test suites compare them, and a message is free to change while a code is
    the thing being agreed on.
    """
    problems: set[str] = set()
    if not cells:
        return ["empty"]

    width, height = canvas
    rects = [(c["x"], c["y"], c["w"], c["h"]) for c in cells]

    for x, y, w, h in rects:
        if w < MIN_CELL_PX or h < MIN_CELL_PX:
            problems.add("under_floor")
        if x < 0 or y < 0 or x + w > width or y + h > height:
            problems.add("off_canvas")

    for i, (ax, ay, aw, ah) in enumerate(rects):
        for bx, by, bw, bh in rects[i + 1:]:
            # Touching edge to edge is not overlapping: a gap of zero is how
            # two cells in a row sit beside each other.
            if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
                problems.add("overlapping")

    if strip_y is not None and strip_h > 0:
        band_top, band_bottom = strip_y, strip_y + strip_h
        for _, y, _, h in rects:
            if y < band_bottom and band_top < y + h:
                problems.add("covers_strip")

    return sorted(problems)
