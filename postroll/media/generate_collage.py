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
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont


# === Design Tokens (shared with brand system) ===

CANVAS_W = 1080
CANVAS_H = 1920

GAP = 8  # slightly wider gaps — more editorial
SIDE_MARGIN = 40  # left/right borders — reduces horizontal stretch, less vertical crop

# Branded center strip
STRIP_H = 90  # compact branded center strip
STRIP_CREAM = (252, 250, 247)  # matches story/before-after cream
STRIP_OPACITY = 230
TEXT_DARK = (60, 55, 50)
ROSE_GOLD = (160, 105, 95)

# Logo
LOGO_WIDTH = 240

# Fonts (shared with brand system)
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"
FONT_DETAIL_THIN = 12

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

# Dedicated 4-photo arrangements (top_pattern, bottom_pattern). The even 2/2
# split only ever yields a flat 2x2 grid, so offer asymmetric hero layouts too.
FOUR_PHOTO_LAYOUTS = [
    ([1], [3]),       # hero over trio
    ([3], [1]),       # trio over hero
    ([2], [2]),       # balanced 2x2 grid
    ([1], [2, 1]),    # hero over (pair then hero)
    ([2, 1], [1]),    # (pair then hero) over hero
]


def choose_collage_split(n: int, rng: random.Random) -> tuple[list[int], list[int]]:
    """Pick (top_pattern, bottom_pattern) for an n-photo masonry collage.

    Each pattern is a list of per-row photo counts. For 4 photos we draw from a
    curated set of dynamic arrangements; for other counts we keep the original
    near-even top/bottom split and choose matching row patterns.
    """
    if n == 4:
        top, bottom = rng.choice(FOUR_PHOTO_LAYOUTS)
        return list(top), list(bottom)
    top_count = n // 2
    bottom_count = n - top_count
    valid_top = [p for p in TOP_PATTERNS if sum(p) == top_count] or [[top_count]]
    valid_bottom = [p for p in BOTTOM_PATTERNS if sum(p) == bottom_count] or [[bottom_count]]
    return rng.choice(valid_top), rng.choice(valid_bottom)


def distinct_collage_splits(n: int) -> list[tuple[list[int], list[int]]]:
    """Every distinct (top_pattern, bottom_pattern) arrangement for n photos.

    The set `choose_collage_split` draws from, enumerated so the layout gallery
    can show one of each structural arrangement instead of random repeats (#70).
    """
    if n == 4:
        return [(list(t), list(b)) for t, b in FOUR_PHOTO_LAYOUTS]
    top_count = n // 2
    bottom_count = n - top_count
    valid_top = [p for p in TOP_PATTERNS if sum(p) == top_count] or [[top_count]]
    valid_bottom = [p for p in BOTTOM_PATTERNS if sum(p) == bottom_count] or [[bottom_count]]
    return [(list(t), list(b)) for t in valid_top for b in valid_bottom]


def _seed_for_split(n: int, target: tuple[list[int], list[int]], limit: int = 100_000) -> int:
    """Find a seed whose `choose_collage_split` yields `target`, so a gallery
    candidate's stored seed reproduces its exact arrangement on final render."""
    want = (tuple(target[0]), tuple(target[1]))
    for seed in range(limit):
        top, bottom = choose_collage_split(n, random.Random(seed))
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


def crop_to_fill(
    photo: Image.Image,
    target_w: int,
    target_h: int,
    crop_offset_x: float = 0.0,
    crop_offset_y: float = 0.0,
    zoom: float = 1.0,
) -> Image.Image:
    """Scale photo to fill target dimensions, then pan/zoom.

    zoom >= 1.0  photo fills (or overfills) the cell; cropped to fit.
    zoom < 1.0   photo is smaller than fill; placed on a blurred bg with pan offset.
    crop_offset_x / crop_offset_y in [-1, 1]: 0 = centred, ±1 = edge.
    """
    photo_ratio = photo.width / photo.height
    target_ratio = target_w / target_h

    if photo_ratio > target_ratio:
        fill_scale = target_h / photo.height
    else:
        fill_scale = target_w / photo.width

    effective_scale = fill_scale * max(zoom, 0.05)
    new_w = int(photo.width * effective_scale)
    new_h = int(photo.height * effective_scale)

    if zoom < 1.0:
        return _place_on_blur(photo, new_w, new_h, target_w, target_h,
                              crop_offset_x, crop_offset_y)

    # zoom >= 1.0 — photo fills/overfills; crop to cell
    resized = photo.resize((new_w, new_h), Image.LANCZOS)
    overflow_x = max(0, new_w - target_w)
    overflow_y = max(0, new_h - target_h)
    left = int(overflow_x * (0.5 + crop_offset_x * 0.5))
    left = max(0, min(overflow_x, left))
    top  = int(overflow_y * (0.5 + crop_offset_y * 0.5))
    top  = max(0, min(overflow_y, top))
    return resized.crop((left, top, left + target_w, top + target_h))


def _place_on_blur(
    photo: Image.Image,
    fit_w: int,
    fit_h: int,
    target_w: int,
    target_h: int,
    crop_offset_x: float,
    crop_offset_y: float,
) -> Image.Image:
    """Place a pre-sized photo (fit_w × fit_h) on a blurred-fill background."""
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

    # Pan within available slack (or overflow) for each axis
    slack_x = target_w - fit_w
    slack_y = target_h - fit_h
    if slack_x >= 0:
        paste_x = int(slack_x * (0.5 + crop_offset_x * 0.5))
        paste_x = max(0, min(slack_x, paste_x))
    else:  # photo still wider than cell
        ox = -slack_x
        paste_x = -int(ox * (0.5 + crop_offset_x * 0.5))
    if slack_y >= 0:
        paste_y = int(slack_y * (0.5 + crop_offset_y * 0.5))
        paste_y = max(0, min(slack_y, paste_y))
    else:
        oy = -slack_y
        paste_y = -int(oy * (0.5 + crop_offset_y * 0.5))

    bg.paste(resized, (paste_x, paste_y))
    return bg


def calculate_row_heights(
    pattern: list[int],
    photos: list[Image.Image],
    total_h: int,
) -> list[int]:
    """Calculate row heights based on photo aspect ratios, scaled to fit."""
    total_gaps_v = (len(pattern) - 1) * GAP
    avail_h = total_h - total_gaps_v

    natural_heights = []
    photo_idx = 0
    for photos_in_row in pattern:
        row_gaps = (photos_in_row - 1) * GAP
        avail_w = CANVAS_W - 2 * SIDE_MARGIN - row_gaps

        ratios = [photos[photo_idx + j].width / photos[photo_idx + j].height
                  for j in range(photos_in_row)]
        natural_h = avail_w / sum(ratios)
        natural_heights.append(natural_h)
        photo_idx += photos_in_row

    total_natural = sum(natural_heights)
    scale = avail_h / total_natural
    heights = [int(h * scale) for h in natural_heights]

    # Fix rounding
    used = sum(heights) + total_gaps_v
    heights[-1] += (total_h - used)
    return heights


def compute_widths(photos_in_row: int, avail_w: int, rng: random.Random) -> list[int]:
    """Compute column widths with intentional asymmetry."""
    if photos_in_row == 1:
        return [avail_w]
    elif photos_in_row == 2:
        split = rng.choice([0.56, 0.44, 0.58, 0.42, 0.55, 0.45])
        w1 = int(avail_w * split)
        return [w1, avail_w - w1]
    elif photos_in_row == 3:
        splits = rng.choice([
            (0.40, 0.30, 0.30),
            (0.30, 0.40, 0.30),
            (0.30, 0.30, 0.40),
            (0.42, 0.30, 0.28),
            (0.28, 0.30, 0.42),
        ])
        w1 = int(avail_w * splits[0])
        w2 = int(avail_w * splits[1])
        return [w1, w2, avail_w - w1 - w2]
    else:
        base = avail_w // photos_in_row
        widths = [base] * photos_in_row
        widths[-1] = avail_w - base * (photos_in_row - 1)
        return widths


def place_photo_rows(
    canvas: Image.Image,
    photos: list[Image.Image],
    pattern: list[int],
    y_start: int,
    total_h: int,
    rng: random.Random,
    offsets: list[tuple[float, float, float]] | None = None,
    photo_paths: list[str] | None = None,
    cells_out: list | None = None,
) -> int:
    """Place rows of photos on the canvas. Returns y position after last row.

    offsets: optional list of (crop_offset_x, crop_offset_y, zoom) parallel to photos.
    photo_paths: optional parallel list of source paths — recorded in cells_out.
    cells_out: optional list to append cell dicts {photo_path, x, y, w, h} to.
    """
    heights = calculate_row_heights(pattern, photos, total_h)
    photo_idx = 0
    y = y_start

    for row_idx, photos_in_row in enumerate(pattern):
        row_h = heights[row_idx]
        row_gaps = (photos_in_row - 1) * GAP
        avail_w = CANVAS_W - 2 * SIDE_MARGIN - row_gaps
        widths = compute_widths(photos_in_row, avail_w, rng)

        x = SIDE_MARGIN
        for col_idx in range(photos_in_row):
            ox, oy, oz = (offsets[photo_idx] if offsets and photo_idx < len(offsets) else (0.0, 0.0, 1.0))
            cropped = crop_to_fill(photos[photo_idx], widths[col_idx], row_h, ox, oy, oz)
            canvas.paste(cropped, (x, y))
            if cells_out is not None and photo_paths and photo_idx < len(photo_paths):
                cells_out.append({
                    "photo_path": photo_paths[photo_idx],
                    "x": x,
                    "y": y,
                    "w": widths[col_idx],
                    "h": row_h,
                })
            x += widths[col_idx] + GAP
            photo_idx += 1

        y += row_h + GAP

    return y


def draw_branded_strip(
    canvas: Image.Image,
    y: int,
    event_name: str,
    org: str,
    venue: str,
    logo_path: str | None,
    photo_tint: tuple[int, int, int],
) -> Image.Image:
    """Draw the branded center strip with event info and logo."""
    # Cream strip with subtle photo tint
    tinted_cream = (
        (STRIP_CREAM[0] * 3 + photo_tint[0]) // 4,
        (STRIP_CREAM[1] * 3 + photo_tint[1]) // 4,
        (STRIP_CREAM[2] * 3 + photo_tint[2]) // 4,
    )
    strip = Image.new("RGBA", (CANVAS_W, STRIP_H), (*tinted_cream, STRIP_OPACITY))
    canvas_rgba = canvas.convert("RGBA")
    canvas_rgba.paste(strip, (0, y), strip)

    draw = ImageDraw.Draw(canvas_rgba)

    # Rose-gold dividers at top and bottom of strip
    draw.line([(0, y), (CANVAS_W, y)], fill=ROSE_GOLD, width=2)
    draw.line([(0, y + STRIP_H - 1), (CANVAS_W, y + STRIP_H - 1)], fill=ROSE_GOLD, width=2)

    # Left side: event name in script + org/venue on same level
    title_font = load_font(FONT_SCRIPT, 42)
    detail_font = load_font(FONT_DETAIL, 18, index=FONT_DETAIL_THIN)

    # Title
    title_x = 35
    title_y = y + 10
    draw.text((title_x, title_y), event_name, font=title_font, fill=TEXT_DARK)

    # Org · Venue below title
    org_venue = f"{org}  ·  {venue}" if org and venue else org or venue
    detail_y = y + 58
    # Draw with spacing
    dx = title_x
    for ch in org_venue:
        draw.text((dx, detail_y), ch, font=detail_font, fill=TEXT_DARK)
        bbox = draw.textbbox((0, 0), ch, font=detail_font)
        dx += (bbox[2] - bbox[0]) + 4

    # Right side: logo
    if logo_path and Path(logo_path).exists():
        logo = Image.open(logo_path).convert("RGBA")
        scale = LOGO_WIDTH / logo.width
        logo = logo.resize(
            (int(logo.width * scale), int(logo.height * scale)),
            Image.LANCZOS,
        )
        lx = CANVAS_W - 30 - logo.width
        ly = y + (STRIP_H - logo.height) // 2
        canvas_rgba.paste(logo, (lx, ly), logo)

    return canvas_rgba


def get_photo_tint(photos: list[Image.Image]) -> tuple[int, int, int]:
    """Sample average color from all photos for cream tinting."""
    total_r, total_g, total_b, count = 0, 0, 0, 0
    for photo in photos:
        small = photo.resize((20, 20), Image.LANCZOS).convert("RGB")
        for r, g, b in small.getdata():
            total_r += r
            total_g += g
            total_b += b
            count += 1
    return (total_r // count, total_g // count, total_b // count)


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
        ox, oy, oz = offsets_by_path.get(path, (0.0, 0.0, 1.0))
        photo = Image.open(path)
        cropped = crop_to_fill(photo, w, h, ox, oy, oz)
        canvas.paste(cropped, (x, y))

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
    """Generate a masonry collage with branded center strip.

    Layout:
        - Top photo rows (5 photos)
        - Branded strip (event name, org/venue, logo) — impossible to crop out
        - Bottom photo rows (5 photos, ends strong)

    crop_offsets: optional list of (x, y, zoom) triples in [-1, 1] / [≥1] parallel to photo_paths.
    cell_layout:  optional list of {photo_path, x, y, w, h} dicts. When provided the masonry
                  pattern is skipped and each photo is rendered at the exact supplied coordinates.
    """
    all_photos = [Image.open(p) for p in photo_paths]

    # Get photo tint for cream coloring (used for canvas background + strip)
    photo_tint = get_photo_tint(all_photos)
    gap_color = (
        (STRIP_CREAM[0] * 2 + photo_tint[0]) // 3,
        (STRIP_CREAM[1] * 2 + photo_tint[1]) // 3,
        (STRIP_CREAM[2] * 2 + photo_tint[2]) // 3,
    )
    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), gap_color)
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
        canvas = draw_branded_strip(
            canvas, strip_y, event_name, org, venue, logo_path, photo_tint
        )
        cells = list(cell_layout)
        mode_desc = f"override ({len(cell_layout)} cells)"
    else:
        # ── Masonry mode: compute layout from photo ratios + pattern ───────
        rng = random.Random(seed)
        n = len(all_photos)
        top_pattern, bottom_pattern = choose_collage_split(n, rng)
        top_count = sum(top_pattern)
        bottom_count = n - top_count
        top_photos = all_photos[:top_count]
        bottom_photos = all_photos[top_count:]

        photo_area_h = CANVAS_H - STRIP_H - GAP
        top_h = int(photo_area_h * 0.50)
        bottom_h = photo_area_h - top_h

        top_offsets = crop_offsets[:top_count] if crop_offsets else None
        bottom_offsets = crop_offsets[top_count:] if crop_offsets else None

        y = 0
        y = place_photo_rows(
            canvas, top_photos, top_pattern, y, top_h, rng, top_offsets,
            photo_paths=list(photo_paths[:top_count]), cells_out=cells,
        )
        strip_y = y - GAP
        canvas = draw_branded_strip(
            canvas, strip_y, event_name, org, venue, logo_path, photo_tint
        )
        bottom_y = strip_y + STRIP_H
        place_photo_rows(
            canvas, bottom_photos, bottom_pattern, bottom_y, bottom_h, rng, bottom_offsets,
            photo_paths=list(photo_paths[top_count:]), cells_out=cells,
        )
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
        layout_path = output.parent / (output.stem + "_layout.json")
        with open(layout_path, "w") as lf:
            json.dump(cells, lf)

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
        splits = distinct_collage_splits(len(photo_paths))[:count]
        seeds = [_seed_for_split(len(photo_paths), split) for split in splits]
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
