"""Split a program page into pieces that each get the model's full image budget.

Why this exists, measured rather than reasoned (#207, five runs per build on the
real BLUDLINE program page):

    whole page capped to a 1568 long edge   "5afa"   0 of 5 correct
    the same band sent as its own image     "Safa"   5 of 5 correct

The mechanism is only arithmetic. A piece is capped by ITS OWN long edge, so a
3024x4032 page scales by 1568/4032 = 0.389 while any full-width band of it
scales by 1568/3024 = 0.518. A third more resolution on the same type, which is
the difference between the two rows above.

That also bounds the work: once a band's width is its long edge, the scale is
budget/width no matter how short the band is. So the useful split is the fewest
bands that make each band no taller than it is wide. More bands buy no
resolution and cost an API call each.

Two rules the same measurement produced:

* Cut in whitespace. A blind 2x2 grid scored 21/28 where sending the page whole
  scored 28/28, because it sliced a two-column name list down the middle.
  Vertical cuts are never made here for that reason; horizontal ones are placed
  in the widest blank gutter near the ideal split, with an overlap so a line
  sitting on the seam is whole in one of the two bands.
* The budget belongs to the RESOLVED MODEL, not to this module. Pinned to 1568
  this fix would silently become a no-op the day the app moves to a model that
  accepts more.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image

from ..ai.model_ids import base_model

#: Longest edge, in pixels, each model will accept before reducing the image
#: itself. Anything not listed falls back to the smallest, because guessing high
#: sends an image that is quietly reduced again, which is the defect this file
#: exists to fix.
_MODEL_IMAGE_BUDGET: dict[str, int] = {
    "claude-sonnet-4-6": 1568,
    "claude-sonnet-4-5": 1568,
    "claude-opus-4-6": 1568,
    "claude-opus-4-5": 1568,
    "claude-haiku-4-5": 1568,
    # The high-resolution tier, which accepts a larger image.
    "claude-opus-4-7": 2576,
    "claude-opus-4-8": 2576,
    "claude-opus-5": 2576,
    "claude-sonnet-5": 2576,
    "claude-fable-5": 2576,
}

DEFAULT_IMAGE_BUDGET = 1568

#: Fraction of a band repeated into its neighbour, so a line of text on the
#: seam appears whole in at least one of them.
BAND_OVERLAP = 0.04

#: A row counts as ink if any sampled pixel is darker than this. Program pages
#: are photographs, so pure white is rare and the threshold has to sit well
#: below paper grey.
_INK_LEVEL = 140


def explicit_image_budget(model: str) -> int | None:
    """The budget this model DECLARES, or None when it declares none.

    Split out from `image_budget_for` so the difference between a declared
    budget and the fallback is something the code can be asked about rather
    than something a caller has to infer from the number (#359). A test walks
    every pinned alias through this; asking `image_budget_for` instead would
    pass just as happily on the fallback.
    """
    from ..ai.claude_client import _resolve_model

    resolved = _resolve_model((model or "").strip())
    declared = _MODEL_IMAGE_BUDGET.get(resolved)
    if declared is not None:
        return declared
    return _MODEL_IMAGE_BUDGET.get(base_model(resolved))


def image_budget_for(model: str) -> int:
    """Longest edge this model accepts before it reduces the image itself."""
    declared = explicit_image_budget(model)
    return DEFAULT_IMAGE_BUDGET if declared is None else declared


def _ink_profile(img: Image.Image, *, along_rows: bool) -> list[bool]:
    """True for each row (or column) that contains any ink."""
    grey = img.convert("L")
    px = grey.load()
    w, h = grey.size
    if along_rows:
        outer, inner = h, w
        get = lambda i, j: px[j, i]  # noqa: E731
    else:
        outer, inner = w, h
        get = lambda i, j: px[i, j]  # noqa: E731

    step = max(1, inner // 200)
    profile = []
    for i in range(outer):
        has_ink = False
        for j in range(0, inner, step):
            if get(i, j) < _INK_LEVEL:
                has_ink = True
                break
        profile.append(has_ink)
    return profile


def _best_seam(profile: list[bool], ideal: int, search: int) -> int:
    """The middle of the widest blank run near `ideal`.

    Falls back to `ideal` when there is no blank run at all, because refusing to
    split would leave the page on the path that is known to misread it.
    """
    lo, hi = max(1, ideal - search), min(len(profile) - 1, ideal + search)
    best_run, run_start, best = None, None, None
    for i in range(lo, hi):
        if not profile[i]:
            if run_start is None:
                run_start = i
        elif run_start is not None:
            length = i - run_start
            if best_run is None or length > best_run:
                best_run, best = length, run_start + length // 2
            run_start = None
    if run_start is not None:
        length = hi - run_start
        if best_run is None or length > best_run:
            best = run_start + length // 2
    return best if best is not None else ideal


def band_bounds(page: Path | str, count: int) -> list[tuple[int, int]]:
    """Start and end offsets of each band, along the page's long axis.

    Bands overlap, and their seams sit in whitespace wherever the page offers
    any. The returned ranges always cover the whole page, so no line of text can
    fall into a gap between two of them.
    """
    img = Image.open(page)
    w, h = img.size
    along_rows = h >= w
    extent = h if along_rows else w
    if count < 2:
        return [(0, extent)]

    profile = _ink_profile(img, along_rows=along_rows)
    span = extent / count
    search = int(span * 0.15)

    seams = [_best_seam(profile, int(span * (i + 1)), search) for i in range(count - 1)]
    seams = sorted(set(seams))

    overlap = int(span * BAND_OVERLAP)
    bounds: list[tuple[int, int]] = []
    edges = [0] + seams + [extent]
    for i in range(len(edges) - 1):
        start = max(0, edges[i] - (overlap if i > 0 else 0))
        end = min(extent, edges[i + 1] + (overlap if i + 1 < len(edges) - 1 else 0))
        bounds.append((start, end))
    return bounds


def band_count(width: int, height: int) -> int:
    """The fewest bands that make each band no taller than it is wide.

    Splitting further buys no resolution, because once the band's width is its
    long edge the scale is budget/width whatever the height, and each extra band
    is another API call.
    """
    long_edge, short_edge = max(width, height), min(width, height)
    return max(1, math.ceil(long_edge / short_edge))


def split_page(page: Path | str, out_dir: Path | str, *, budget: int) -> list[Path]:
    """Write `page` as one image per band, in reading order.

    Returns the original path unchanged when the page already fits the budget:
    there is nothing to gain, and re-encoding it would only lose a little.
    """
    page = Path(page)
    img = Image.open(page)
    w, h = img.size
    if max(w, h) <= budget:
        return [page]

    count = band_count(w, h)
    if count < 2:
        return [page]

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    along_rows = h >= w

    regions: list[Path] = []
    for i, (start, end) in enumerate(band_bounds(page, count)):
        box = (0, start, w, end) if along_rows else (start, 0, end, h)
        band = img.crop(box)
        # Named so the caller's list, and anything that sorts it, stays in
        # reading order; a shuffled program reads as a different program.
        target = out_dir / f"{page.stem}_band{i:02d}.png"
        band.save(target)
        regions.append(target)
    return regions
