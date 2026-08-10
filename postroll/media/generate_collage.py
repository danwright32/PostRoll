"""
PostRoll — Masonry Collage Generator

Creates a 1080x1920 masonry-style collage from 10 photos with a branded
center strip. Used for: Wednesday collage story.

Layout: photos top half → branded strip (title/org/venue/logo) → photos bottom half.
The branded strip is impossible to crop out when shared.

Usage:
    python generate_collage.py \
        --photos photo1.jpg ... photo10.jpg \
        --event "Sing/Play" --org "DCINY" --venue "Carnegie Hall" \
        --output output/collage.png
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

# The brand palette, type and mat scale live in one module (#162). Aliased to
# the names this template has always used where the local name reads better in
# context; the value is the shared one either way.
from .design_tokens import (
    CREAM as STRIP_CREAM,
    FONT_DETAIL,
    FONT_DETAIL_LIGHT as PLATE_DETAIL_WEIGHT,
    FONT_SCRIPT,
    GUTTER as GAP,
    HAIRLINE,
    MAT_GALLERY as MAT,
    TEXT_DARK,
)
from .brand_text import detail_lines
from .layout_sidecar import layout_sidecar_path
# Aliased: `write_layout_sidecar` is already the name of this module's
# boolean parameter for whether to write one at all.
from .layout_sidecar import write_layout_sidecar as _write_sidecar

# MAT is the gallery mat: an even cream border on all four sides with the photos
# hung inside it. The photos used to bleed off the top and bottom of the canvas
# with a 40px side border only, so nothing read as matted.
#
# HAIRLINE is the 1px ring immediately OUTSIDE each cell, so a print is framed
# without the line eating a row of the photograph. Swift strokes the same ring
# (CollageGeometry.hairlineRect) after it repaints the gutters, because a
# hairline baked only into this PNG would be painted over on export.


# === Layout, specific to this template ===

CANVAS_W = 1080
CANVAS_H = 1920

# Branded center strip: a caption plate inset to the mat, not an edge-to-edge band.
STRIP_H = 90

# Logo
LOGO_WIDTH = 240
PLATE_PADDING = 24  # inset of the plate's text and logo from its own edges

# Layout patterns: (top_half, bottom_half) — photos split around center strip
# Top gets 5, bottom gets 5
TOP_PATTERNS = [
    [1, 2, 2],      # hero → pair → pair
    [2, 1, 2],      # pair → hero → pair
    [1, 3, 1],      # hero → trio → hero
    [2, 2, 1],      # pair → pair → hero
]

BOTTOM_PATTERNS = [
    [2, 2, 1],      # pair → pair → hero (strong close)
    [2, 1, 2],      # pair → hero → pair
    [1, 2, 2],      # hero → pair → pair
    [3, 2],          # trio → pair (compact)
    [2, 3],          # pair → trio
]

# Row patterns for a half holding 1-4 photos. TOP/BOTTOM_PATTERNS only cover the
# 5-photo half of a 10-photo collage; without these, a 6-photo collage fell back
# to a single [3] row per half, the same sliver crop as the 4-photo case.
SMALL_HALF_PATTERNS: dict[int, list[list[int]]] = {
    1: [[1]],
    2: [[2], [1, 1]],
    3: [[3], [2, 1], [1, 2], [1, 1, 1]],
    4: [[2, 2], [1, 3], [3, 1], [1, 2, 1], [2, 1, 1], [1, 1, 2], [1, 1, 1, 1]],
}

# Dedicated 4-photo arrangements (top_pattern, bottom_pattern). The even 2/2
# split only ever yields a flat 2x2 grid, so offer asymmetric hero layouts too.
FOUR_PHOTO_LAYOUTS = [
    ([1], [3]),       # hero over trio
    ([3], [1]),       # trio over hero
    ([2], [2]),       # balanced 2x2 grid
    ([1], [2, 1]),    # hero over (pair then hero)
    ([2, 1], [1]),    # (pair then hero) over hero
    ([1, 1], [1, 1]), # four full-width bands
]

# Column width splits per row size. Shared by the renderer and the crop-budget
# check so the two can't disagree about how narrow a column may get.
WIDTH_SPLITS: dict[int, list[tuple[float, ...]]] = {
    1: [(1.0,)],
    2: [(0.56, 0.44), (0.44, 0.56), (0.58, 0.42),
        (0.42, 0.58), (0.55, 0.45), (0.45, 0.55)],
    3: [(0.40, 0.30, 0.30), (0.30, 0.40, 0.30), (0.30, 0.30, 0.40),
        (0.42, 0.30, 0.28), (0.28, 0.30, 0.42)],
}

# === Crop budget ===
#
# Every photo is fill-cropped into its cell, so a cell whose shape disagrees with
# the frame's shape throws pixels away. The budget is deliberately asymmetric:
# trimming a landscape frame's top and bottom is a normal photographic crop, but
# cutting into its sides destroys the composition. Dan shoots 3:2 landscape, and
# the old fixed-height halves could hand a 3:2 frame a 0.32-aspect slot, keeping
# 22% of its width.
#
# Height may go to 45% (a 3:2 frame becomes a ~3.3:1 band, a strong but honest
# editorial crop). Width may not go below 62%, which is what kills the slivers.
MIN_WIDTH_RETENTION = 0.62
MIN_HEIGHT_RETENTION = 0.45

# The branded strip is the thing a re-sharer can't crop out, so it has to stay
# near the middle even though it now floats to a natural row boundary.
STRIP_MIN_FRACTION = 0.30
STRIP_MAX_FRACTION = 0.70


def cell_retention(cell_w: float, cell_h: float, photo_ratio: float) -> float:
    """Fraction of the constrained axis a fill-crop into this cell keeps.

    Returns 1.0 when the cell matches the frame. Below that, the shorter of the
    two axes is the one being cropped away.
    """
    cell_ratio = cell_w / cell_h
    if photo_ratio > cell_ratio:
        return cell_ratio / photo_ratio   # cell is narrower than the frame → width lost
    return photo_ratio / cell_ratio       # cell is taller than the frame → height lost


def _row_heights(rows: list[int], photo_ratios: list[float]) -> list[int]:
    """Height of each row under ONE scale shared across the whole canvas.

    This is the fix for the sliver crop. Each half used to be forced to exactly
    half the photo area, so a half holding a single row stretched that row to
    ~911px no matter what shape its photos were. Sizing every row from its
    photos' real aspect ratios and scaling them all together means a row is only
    ever as tall as its share of the canvas, not as tall as its half.
    """
    inner_gaps = max(0, len(rows) - 2)   # one boundary carries the strip instead
    avail_h = CANVAS_H - 2 * MAT - STRIP_H - inner_gaps * GAP

    naturals: list[float] = []
    idx = 0
    for photos_in_row in rows:
        avail_w = CANVAS_W - 2 * MAT - (photos_in_row - 1) * GAP
        naturals.append(avail_w / sum(photo_ratios[idx:idx + photos_in_row]))
        idx += photos_in_row

    scale = avail_h / sum(naturals)
    heights = [int(h * scale) for h in naturals]
    heights[-1] += avail_h - sum(heights)   # absorb rounding into the last row
    return heights


def plan_collage_cells(
    photo_ratios: list[float],
    top_pattern: list[int],
    bottom_pattern: list[int],
    rng: random.Random,
) -> tuple[list[dict], int]:
    """Lay out every cell for a split, returning (cells, strip_y).

    Cells carry {index, x, y, w, h} in canvas pixels. The branded strip sits at
    the boundary between the last top row and the first bottom row, wherever the
    photo shapes put that boundary.
    """
    rows = list(top_pattern) + list(bottom_pattern)
    heights = _row_heights(rows, photo_ratios)

    cells: list[dict] = []
    strip_y = 0
    photo_idx = 0
    y = MAT   # hang the first row below the top mat

    for row_idx, photos_in_row in enumerate(rows):
        row_h = heights[row_idx]
        avail_w = CANVAS_W - 2 * MAT - (photos_in_row - 1) * GAP
        widths = compute_widths(photos_in_row, avail_w, rng)

        x = MAT
        for col_idx in range(photos_in_row):
            cells.append({
                "index": photo_idx,
                "x": x,
                "y": y,
                "w": widths[col_idx],
                "h": row_h,
            })
            x += widths[col_idx] + GAP
            photo_idx += 1

        y += row_h
        if row_idx == len(top_pattern) - 1:
            strip_y = y
            y += STRIP_H
        elif row_idx < len(rows) - 1:
            y += GAP

    return cells, strip_y


def split_fits_photos(
    split: tuple[list[int], list[int]],
    photo_ratios: list[float],
) -> bool:
    """Does this arrangement stay inside the crop budget for these photos?

    Checked against the WORST column width the row could draw, not the one a
    particular seed happens to pick, so a layout can't pass validation and then
    render a sliver on a different seed.
    """
    top_pattern, bottom_pattern = split
    rows = list(top_pattern) + list(bottom_pattern)
    if sum(rows) != len(photo_ratios):
        return False

    heights = _row_heights(rows, photo_ratios)

    # The strip must not drift to an edge, or it stops being a centre strip.
    strip_y = MAT + sum(heights[:len(top_pattern)]) + max(0, len(top_pattern) - 1) * GAP
    if not (STRIP_MIN_FRACTION * CANVAS_H <= strip_y <= STRIP_MAX_FRACTION * CANVAS_H):
        return False

    photo_idx = 0
    for row_idx, photos_in_row in enumerate(rows):
        row_h = heights[row_idx]
        if row_h <= 0:
            return False
        avail_w = CANVAS_W - 2 * MAT - (photos_in_row - 1) * GAP

        for fractions in WIDTH_SPLITS.get(photos_in_row, [(1.0 / photos_in_row,) * photos_in_row]):
            for col_idx, fraction in enumerate(fractions):
                ratio = photo_ratios[photo_idx + col_idx]
                cell_w = avail_w * fraction
                keep = cell_retention(cell_w, row_h, ratio)
                cropping_width = (cell_w / row_h) < ratio
                floor = MIN_WIDTH_RETENTION if cropping_width else MIN_HEIGHT_RETENTION
                if keep < floor:
                    return False

        photo_idx += photos_in_row

    return True


def _half_patterns(count: int, pool: list[list[int]]) -> list[list[int]]:
    """Row patterns for a half holding `count` photos."""
    from_pool = [p for p in pool if sum(p) == count]
    if from_pool:
        return from_pool
    return SMALL_HALF_PATTERNS.get(count) or [[count]]


def _all_splits(n: int) -> list[tuple[list[int], list[int]]]:
    """Every arrangement for n photos, before the crop budget is applied."""
    if n == 4:
        return [(list(t), list(b)) for t, b in FOUR_PHOTO_LAYOUTS]
    top_count = n // 2
    bottom_count = n - top_count
    valid_top = _half_patterns(top_count, TOP_PATTERNS)
    valid_bottom = _half_patterns(bottom_count, BOTTOM_PATTERNS)
    return [(list(t), list(b)) for t in valid_top for b in valid_bottom]


def distinct_collage_splits(
    n: int,
    photo_ratios: list[float] | None = None,
) -> list[tuple[list[int], list[int]]]:
    """Every distinct (top_pattern, bottom_pattern) arrangement for n photos.

    The set `choose_collage_split` draws from, enumerated so the layout gallery
    can show one of each structural arrangement instead of random repeats (#70).

    With `photo_ratios`, arrangements that would breach the crop budget for those
    specific photos are dropped. This is what makes the layout shape-aware: a
    3-across row survives where the row is naturally short, and disappears where
    it would have to be stretched into slivers.
    """
    splits = _all_splits(n)
    if photo_ratios is None:
        return splits

    fitting = [s for s in splits if split_fits_photos(s, photo_ratios)]
    if fitting:
        return fitting

    # No arrangement in the pool can hold these photos without breaching the crop
    # budget. Say so rather than quietly rendering the sliver anyway.
    print(
        f"WARNING: no collage layout fits {n} photos of aspect "
        f"{[round(r, 2) for r in photo_ratios]} within the crop budget "
        f"(width ≥ {MIN_WIDTH_RETENTION:.0%}, height ≥ {MIN_HEIGHT_RETENTION:.0%}). "
        f"Falling back to {splits[0]}, which will crop harder than intended.",
        file=sys.stderr,
    )
    return splits[:1]


def choose_collage_split(
    n: int,
    rng: random.Random,
    photo_ratios: list[float] | None = None,
) -> tuple[list[int], list[int]]:
    """Pick (top_pattern, bottom_pattern) for an n-photo masonry collage.

    Each pattern is a list of per-row photo counts. When `photo_ratios` is given,
    only arrangements that respect the crop budget for those photos are drawn.
    """
    options = distinct_collage_splits(n, photo_ratios)
    top, bottom = rng.choice(options)
    return list(top), list(bottom)


def _seed_for_split(
    n: int,
    target: tuple[list[int], list[int]],
    photo_ratios: list[float] | None = None,
    limit: int = 100_000,
) -> int:
    """Find a seed whose `choose_collage_split` yields `target`, so a gallery
    candidate's stored seed reproduces its exact arrangement on final render."""
    want = (tuple(target[0]), tuple(target[1]))
    for seed in range(limit):
        top, bottom = choose_collage_split(n, random.Random(seed), photo_ratios)
        if (tuple(top), tuple(bottom)) == want:
            return seed
    return 0


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        return ImageFont.load_default()


def draw_spaced_text_centered(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    fill: tuple,
    center_x: int,
    y: int,
    spacing: int = 8,
):
    """Draw text with wide letter spacing, centered horizontally."""
    total_w = 0
    for ch in text:
        bbox = draw.textbbox((0, 0), ch, font=font)
        total_w += (bbox[2] - bbox[0]) + spacing
    total_w -= spacing
    x = center_x - total_w // 2
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        bbox = draw.textbbox((0, 0), ch, font=font)
        x += (bbox[2] - bbox[0]) + spacing


# The vertical framing every crop starts from: the photo's top edge.
#
# Performing-arts frames compose the subject in the upper part of the picture,
# so a centred fill quietly takes a slice off the heads. The pixels a fill has
# to discard come off the BOTTOM, always (#167). Mirrors CropOffset.topAnchoredY
# on the Swift side; the two must move together or the editor shows one framing
# and the export produces another.
TOP_ANCHORED_CROP_Y = -1.0

# What an unset per-photo offset means, shared by every call site so the rule
# can't be applied to some surfaces and not others. `None` for y is "unset",
# which resolves to the top-anchored default.
DEFAULT_CROP_OFFSET: tuple[float, float | None, float] = (0.0, None, 1.0)

# The smallest zoom the geometry honours. It is the floor of the editor's SIZE
# slider (0.25 to 2.5), so nothing below it can be produced by hand; a smaller
# value can only arrive from stored data, and both languages must clamp it the
# same way or one saved value renders at two different sizes.
ZOOM_FLOOR = 0.25


def crop_placement(
    photo_w: int,
    photo_h: int,
    target_w: int,
    target_h: int,
    crop_offset_x: float = 0.0,
    crop_offset_y: float | None = None,
    zoom: float = 1.0,
) -> tuple[float, float, float, float]:
    """The crop/pan contract: where a photo lands inside its cell.

    Returns (rendered_w, rendered_h, draw_x, draw_y), where draw_x/draw_y are
    the rendered photo's top-left corner relative to the cell's top-left. A
    negative value means the photo overflows and that much is cropped away on
    that side; a positive one means it has slack and is inset.

    This is the geometry `CollageGeometry.placement` computes on the Swift side,
    and `tests/fixtures/crop_geometry.json` is the contract both must satisfy
    (#168). The two are separate implementations in separate languages, so
    nothing but that fixture stops them drifting, and when they drift Dan sees
    one framing in the editor and gets another in the exported file.

    An offset only chooses which slice of an OVERFLOWING photo is kept. On an
    axis where the photo is smaller than its cell there is nothing to discard,
    so it is centred whatever the offset says, matching what the editor draws
    (it refuses to commit a pan on an axis without overflow).
    """
    if crop_offset_y is None:
        crop_offset_y = TOP_ANCHORED_CROP_Y

    photo_ratio = photo_w / photo_h
    target_ratio = target_w / target_h

    if photo_ratio > target_ratio:
        fill_scale = target_h / photo_h
    else:
        fill_scale = target_w / photo_w

    effective_scale = fill_scale * max(zoom, ZOOM_FLOOR)
    rendered_w = photo_w * effective_scale
    rendered_h = photo_h * effective_scale

    overflow_w = rendered_w - target_w
    overflow_h = rendered_h - target_h

    draw_x = (-overflow_w * (0.5 + crop_offset_x * 0.5)) if overflow_w > 0 \
        else (target_w - rendered_w) / 2
    draw_y = (-overflow_h * (0.5 + crop_offset_y * 0.5)) if overflow_h > 0 \
        else (target_h - rendered_h) / 2

    return rendered_w, rendered_h, draw_x, draw_y


def crop_to_fill(
    photo: Image.Image,
    target_w: int,
    target_h: int,
    crop_offset_x: float = 0.0,
    crop_offset_y: float | None = None,
    zoom: float = 1.0,
) -> Image.Image:
    """Scale photo to fill target dimensions, then pan/zoom.

    zoom >= 1.0  photo fills (or overfills) the cell; cropped to fit.
    zoom < 1.0   photo is smaller than fill; placed on a blurred bg.
    crop_offset_x / crop_offset_y in [-1, 1]: 0 = centred, ±1 = edge.

    All the geometry comes from `crop_placement`; this only rasterises it.
    """
    rendered_w, rendered_h, draw_x, draw_y = crop_placement(
        photo.width, photo.height, target_w, target_h,
        crop_offset_x, crop_offset_y, zoom)

    new_w = int(rendered_w)
    new_h = int(rendered_h)

    if zoom < 1.0:
        return _place_on_blur(photo, new_w, new_h, target_w, target_h,
                              int(draw_x), int(draw_y))

    # zoom >= 1.0 — photo fills/overfills; crop to cell
    resized = photo.resize((new_w, new_h), Image.LANCZOS)
    left = max(0, min(max(0, new_w - target_w), int(-draw_x)))
    top  = max(0, min(max(0, new_h - target_h), int(-draw_y)))
    return resized.crop((left, top, left + target_w, top + target_h))


def _place_on_blur(
    photo: Image.Image,
    fit_w: int,
    fit_h: int,
    target_w: int,
    target_h: int,
    paste_x: int,
    paste_y: int,
) -> Image.Image:
    """Paint a pre-sized photo (fit_w × fit_h) at (paste_x, paste_y) on a
    blurred-fill background. The position comes from `crop_placement`, so this
    holds no framing rule of its own."""
    # Blurred background: scale photo to fill cell
    bg_ratio = photo.width / photo.height
    cell_ratio = target_w / target_h
    if bg_ratio > cell_ratio:
        bg_scale = target_h / photo.height
    else:
        bg_scale = target_w / photo.width
    bg_w = int(photo.width * bg_scale)
    bg_h = int(photo.height * bg_scale)
    bg = photo.resize((bg_w, bg_h), Image.LANCZOS)
    bg_left = (bg_w - target_w) // 2
    bg_top  = (bg_h - target_h) // 2
    bg = bg.crop((bg_left, bg_top, bg_left + target_w, bg_top + target_h))
    bg = bg.filter(ImageFilter.GaussianBlur(radius=30))
    darken = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 80))
    bg = Image.alpha_composite(bg.convert("RGBA"), darken).convert("RGB")

    resized = photo.resize((fit_w, fit_h), Image.LANCZOS)
    bg.paste(resized, (paste_x, paste_y))
    return bg


def compute_widths(photos_in_row: int, avail_w: int, rng: random.Random) -> list[int]:
    """Compute column widths with intentional asymmetry."""
    options = WIDTH_SPLITS.get(photos_in_row)
    if not options:
        base = avail_w // photos_in_row
        widths = [base] * photos_in_row
        widths[-1] = avail_w - base * (photos_in_row - 1)
        return widths

    fractions = rng.choice(options)
    widths = [int(avail_w * f) for f in fractions[:-1]]
    widths.append(avail_w - sum(widths))
    return widths


def paste_planned_cells(
    canvas: Image.Image,
    photos: list[Image.Image],
    photo_paths: list[str],
    cells: list[dict],
    offsets: list[tuple[float, float, float]] | None = None,
) -> list[dict]:
    """Paste each photo into its planned cell. Returns the layout sidecar cells.

    offsets: optional (crop_offset_x, crop_offset_y, zoom) triples parallel to photos.
    """
    sidecar: list[dict] = []
    for cell in cells:
        idx = cell["index"]
        ox, oy, oz = (offsets[idx] if offsets and idx < len(offsets) else DEFAULT_CROP_OFFSET)
        cropped = crop_to_fill(photos[idx], cell["w"], cell["h"], ox, oy, oz)
        canvas.paste(cropped, (cell["x"], cell["y"]))
        sidecar.append({
            "photo_path": photo_paths[idx],
            "x": cell["x"],
            "y": cell["y"],
            "w": cell["w"],
            "h": cell["h"],
        })
    draw_hairlines(canvas, sidecar)
    return sidecar


def draw_hairlines(canvas: Image.Image, cells: list[dict]) -> None:
    """Frame each print with a 1px ring immediately outside its cell.

    Outside, never inside: the line must not consume a row of the photograph.
    `CollageGeometry.hairlineRect` strokes the identical ring on the Swift side.
    """
    draw = ImageDraw.Draw(canvas)
    for cell in cells:
        x, y, w, h = cell["x"], cell["y"], cell["w"], cell["h"]
        draw.rectangle([x - 1, y - 1, x + w, y + h], outline=HAIRLINE, width=1)


def plate_detail_line(event_name: str, org: str, venue: str) -> str:
    """The text under the script title on the caption plate.

    Which lines there are is `brand_text.detail_lines`, shared with every other
    template. The middle dot joining them is this plate's own layout: the
    collage puts them on one line where the reels stack them.
    """
    return "  ·  ".join(detail_lines(event_name, org, venue))


def draw_branded_strip(
    canvas: Image.Image,
    y: int,
    event_name: str,
    org: str,
    venue: str,
    logo_path: str | None,
) -> Image.Image:
    """Draw the caption plate: event info and logo, inset to the mat.

    The plate is fixed brand cream. It used to be blended a quarter of the way
    toward the photos' average colour, which made the logo lockup a different
    colour at every event (grey-blue under a blue stage, muddy grey in a dark
    room). A brand mark that changes colour with the stage lighting is not a
    brand mark.
    """
    left = MAT
    right = CANVAS_W - MAT

    canvas_rgba = canvas.convert("RGBA")
    plate = Image.new("RGBA", (right - left, STRIP_H), (*STRIP_CREAM, 255))
    canvas_rgba.paste(plate, (left, y), plate)

    draw = ImageDraw.Draw(canvas_rgba)

    # No rule lines: the plate is cream on a cream mat, so a rule would read as a
    # leftover divider from the old edge-to-edge strip.

    title_font = load_font(FONT_SCRIPT, 42)
    detail_font = load_font(FONT_DETAIL, 18, index=PLATE_DETAIL_WEIGHT)

    title_x = left + PLATE_PADDING
    draw.text((title_x, y + 10), event_name, font=title_font, fill=TEXT_DARK)

    detail = plate_detail_line(event_name, org, venue)
    dx = title_x
    for ch in detail:
        draw.text((dx, y + 58), ch, font=detail_font, fill=TEXT_DARK)
        bbox = draw.textbbox((0, 0), ch, font=detail_font)
        dx += (bbox[2] - bbox[0]) + 4

    if logo_path and Path(logo_path).exists():
        logo = Image.open(logo_path).convert("RGBA")
        scale = LOGO_WIDTH / logo.width
        logo = logo.resize(
            (int(logo.width * scale), int(logo.height * scale)),
            Image.LANCZOS,
        )
        lx = right - PLATE_PADDING - logo.width
        ly = y + (STRIP_H - logo.height) // 2
        canvas_rgba.paste(logo, (lx, ly), logo)

    return canvas_rgba


def render_cell_layout_override(
    canvas: Image.Image,
    cell_layout: list[dict],
    offsets_by_path: dict[str, tuple[float, float, float]],
) -> int:
    """Render cells at exact (x,y,w,h) positions from cell_layout.

    Returns the inferred strip_y — the bottom of the last cell before the
    largest inter-row gap (where the original strip was placed).
    """
    for cell in cell_layout:
        path = cell["photo_path"]
        x, y, w, h = cell["x"], cell["y"], cell["w"], cell["h"]
        ox, oy, oz = offsets_by_path.get(path, DEFAULT_CROP_OFFSET)
        photo = Image.open(path)
        cropped = crop_to_fill(photo, w, h, ox, oy, oz)
        canvas.paste(cropped, (x, y))

    draw_hairlines(canvas, cell_layout)

    # Group cells into rows by y-overlap
    sorted_cells = sorted(cell_layout, key=lambda c: c["y"])
    rows: list[list[dict]] = []
    current: list[dict] = [sorted_cells[0]]
    for cell in sorted_cells[1:]:
        row_max_y = max(c["y"] + c["h"] for c in current)
        if cell["y"] < row_max_y:
            current.append(cell)
        else:
            rows.append(current)
            current = [cell]
    rows.append(current)

    if len(rows) < 2:
        return max(c["y"] + c["h"] for c in cell_layout)

    row_bottoms = [max(c["y"] + c["h"] for c in row) for row in rows]
    row_tops = [min(c["y"] for c in row) for row in rows]
    # The strip sits in the largest inter-row gap
    gaps = [(row_tops[i + 1] - row_bottoms[i], row_bottoms[i]) for i in range(len(rows) - 1)]
    _, strip_y = max(gaps, key=lambda g: g[0])
    return strip_y


def usable_cell_layout(
    cell_layout: list[dict] | None, photo_paths: list[str]
) -> list[dict] | None:
    """``cell_layout`` if it still describes ``photo_paths``, else None.

    A saved layout records whatever paths were in play when the user dragged the
    frames. Changing the day's photos, or moving the originals into app storage,
    leaves cells naming files that may no longer exist. Rendering such a layout
    means opening a missing file, which used to raise out of the whole render:
    one stale layout stopped the Wednesday collage (and so the Wednesday story)
    generating at all, on every retry.

    Usable means one cell per photo, every cell on a photo this collage is being
    built from, and every file present on disk. Anything else falls back to the
    automatic layout: the collage is the deliverable, the override is a nicety.
    The caller (Swift) applies the same rule, so this is the render's own backstop.
    """
    if not cell_layout:
        return None
    wanted = {str(Path(p)) for p in photo_paths}
    cell_names = [str(Path(c.get("photo_path", ""))) for c in cell_layout]
    reasons: list[str] = []
    if len(cell_layout) != len(photo_paths):
        reasons.append(f"{len(cell_layout)} cells for {len(photo_paths)} photos")
    if set(cell_names) != wanted:
        reasons.append("cells name a different photo set")
    missing = [n for n in cell_names if not Path(n).exists()]
    if missing:
        reasons.append(f"{len(missing)} cell file(s) missing, first: {missing[0]}")
    if reasons:
        print(
            f"[generate_collage] cell_layout ignored ({'; '.join(reasons)}). "
            "Using the automatic layout instead.",
            flush=True, file=sys.stderr,
        )
        return None
    return cell_layout


def generate_collage(
    photo_paths: list[str],
    output_path: str,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    logo_path: str | None = None,
    seed: int | None = None,
    crop_offsets: list[tuple[float, float, float]] | None = None,
    cell_layout: list[dict] | None = None,
    write_layout_sidecar: bool = True,
) -> str:
    """Generate a gallery-style collage: photos matted in cream, caption plate between.

    Layout:
        - Top photo rows, hung inside an even cream mat
        - Caption plate (event name, org/venue, logo), inset to the mat
        - Bottom photo rows

    Rows are sized from the photos' real aspect ratios under one shared scale, and
    arrangements that would crop a frame past the budget are never offered. See
    `split_fits_photos`.

    crop_offsets: optional list of (x, y, zoom) triples in [-1, 1] / [≥1] parallel to photo_paths.
    cell_layout:  optional list of {photo_path, x, y, w, h} dicts. When provided the masonry
                  pattern is skipped and each photo is rendered at the exact supplied coordinates.
    """
    all_photos = [Image.open(p) for p in photo_paths]
    cell_layout = usable_cell_layout(cell_layout, photo_paths)

    # The mat is fixed brand cream. It used to be blended toward the photos'
    # average colour, so a blue stage greyed it and a dark room dirtied it.
    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), STRIP_CREAM)
    cells: list[dict] = []

    if cell_layout:
        # ── Override mode: render at user-specified positions ──────────────
        offsets_by_path: dict[str, tuple[float, float, float]] = {}
        if crop_offsets:
            for i, path in enumerate(photo_paths):
                if i < len(crop_offsets):
                    t = crop_offsets[i]
                    offsets_by_path[path] = (float(t[0]), float(t[1]), float(t[2]))

        strip_y = render_cell_layout_override(canvas, cell_layout, offsets_by_path)
        canvas = draw_branded_strip(canvas, strip_y, event_name, org, venue, logo_path)
        cells = list(cell_layout)
        mode_desc = f"override ({len(cell_layout)} cells)"
    else:
        # ── Masonry mode: compute layout from photo ratios + pattern ───────
        n = len(all_photos)
        ratios = [p.width / p.height for p in all_photos]
        options = distinct_collage_splits(n, ratios)

        # With no stored seed the collage must be deterministic, not a fresh draw
        # every render. The first fitting arrangement is the default.
        rng = random.Random(0 if seed is None else seed)
        if seed is None:
            top_pattern, bottom_pattern = [list(p) for p in options[0]]
        else:
            top_pattern, bottom_pattern = choose_collage_split(n, rng, ratios)

        planned, strip_y = plan_collage_cells(ratios, top_pattern, bottom_pattern, rng)

        cells = paste_planned_cells(
            canvas, all_photos, list(photo_paths), planned, crop_offsets
        )
        canvas = draw_branded_strip(canvas, strip_y, event_name, org, venue, logo_path)
        mode_desc = f"top={top_pattern}, bottom={bottom_pattern}"

    # Save PNG
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas_rgb = canvas.convert("RGB") if canvas.mode != "RGB" else canvas
    canvas_rgb.save(str(output), "PNG", quality=95)

    # Save layout sidecar — used by the caption-review editor to overlay
    # crop controls. Suppressed on final export since nothing in the
    # export folder consumes it.
    if write_layout_sidecar:
        _write_sidecar(layout_sidecar_path(output), cells)

    print(f"Collage generated: {output} ({CANVAS_W}x{CANVAS_H}, {mode_desc})")
    return str(output)


def generate_collage_candidates(
    photo_paths: list[str],
    output_dir: str,
    count: int,
    *,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    logo_path: str | None = None,
    seeds: list[int] | None = None,
    crop_offsets: list[tuple[float, float, float]] | None = None,
) -> list[dict]:
    """Render `count` distinct collage layouts (one per seed) for a layout picker.

    Returns a list of {"seed": int, "path": str} dicts. The caller stores the
    chosen seed as the day's collage_seed so the final render reproduces it. No
    layout sidecar is written — these are throwaway previews.

    crop_offsets: optional per-photo (x, y, zoom) triples, parallel to
    photo_paths, so the gallery thumbnails match the user's saved crop edits.
    """
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    if seeds is None:
        # Pick one seed per distinct structural arrangement so the gallery shows
        # genuinely different layouts, not random repeats (#70). Each seed
        # reproduces its arrangement on the final render.
        #
        # The pool is filtered by the photos' own aspect ratios, so the gallery
        # can only ever offer layouts that stay inside the crop budget for THIS
        # set. generate_collage() filters with the same ratios, so a candidate's
        # stored seed still reproduces exactly the layout that was shown.
        ratios = []
        for p in photo_paths:
            with Image.open(p) as im:
                ratios.append(im.width / im.height)
        splits = distinct_collage_splits(len(photo_paths), ratios)[:count]
        seeds = [_seed_for_split(len(photo_paths), split, ratios) for split in splits]
    results: list[dict] = []
    for seed in seeds:
        out = out_dir / f"candidate_{seed}.png"
        generate_collage(
            photo_paths=photo_paths,
            output_path=str(out),
            event_name=event_name,
            org=org,
            venue=venue,
            logo_path=logo_path,
            seed=seed,
            crop_offsets=crop_offsets,
            write_layout_sidecar=False,
        )
        results.append({"seed": seed, "path": str(out)})
    return results


def main():
    parser = argparse.ArgumentParser(description="Generate a masonry collage")
    parser.add_argument("--photos", nargs="+", required=True)
    parser.add_argument("--event", default="", help="Event name")
    parser.add_argument("--org", default="", help="Organization")
    parser.add_argument("--venue", default="", help="Venue")
    parser.add_argument("--logo", default=None, help="Path to DW logo")
    parser.add_argument("--output", default="output/collage.png")
    parser.add_argument("--seed", type=int, default=None)
    # Layout-gallery mode: render N candidate layouts and print JSON to stdout.
    parser.add_argument("--candidates", type=int, default=0,
                        help="Render this many candidate layouts instead of one")
    parser.add_argument("--candidates-out", default=None,
                        help="Directory to write candidate PNGs into")
    parser.add_argument("--candidates-json", default=None,
                        help="Write the [{seed, path}] list as JSON to this file")
    parser.add_argument("--crop-offsets-json", default=None,
                        help="JSON file with a list of [x, y, zoom] triples parallel to --photos")
    args = parser.parse_args()

    crop_offsets = None
    if args.crop_offsets_json:
        raw = json.loads(Path(args.crop_offsets_json).read_text(encoding="utf-8"))
        crop_offsets = [tuple(o) for o in raw]

    if args.candidates > 0:
        results = generate_collage_candidates(
            photo_paths=args.photos,
            output_dir=args.candidates_out or "output/candidates",
            count=args.candidates,
            event_name=args.event,
            org=args.org,
            venue=args.venue,
            logo_path=args.logo,
            crop_offsets=crop_offsets,
        )
        payload = json.dumps(results)
        if args.candidates_json:
            Path(args.candidates_json).write_text(payload, encoding="utf-8")
        else:
            # Sentinel-prefixed so the caller can find this line among the
            # per-candidate "Collage generated" progress prints on stdout.
            print("CANDIDATES_JSON " + payload)
        return

    generate_collage(
        photo_paths=args.photos,
        output_path=args.output,
        event_name=args.event,
        org=args.org,
        venue=args.venue,
        logo_path=args.logo,
        seed=args.seed,
    )


if __name__ == "__main__":
    main()
