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
import random
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


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


def crop_to_fill(photo: Image.Image, target_w: int, target_h: int) -> Image.Image:
    """Crop and resize photo to fill target dimensions.
    Biases vertical crop toward the top (keeps heads/faces visible).
    """
    photo_ratio = photo.width / photo.height
    target_ratio = target_w / target_h

    if photo_ratio > target_ratio:
        scale = target_h / photo.height
    else:
        scale = target_w / photo.width

    new_w = int(photo.width * scale)
    new_h = int(photo.height * scale)
    resized = photo.resize((new_w, new_h), Image.LANCZOS)

    left = (new_w - target_w) // 2
    overflow = new_h - target_h
    top = int(overflow * 0.4)  # slight top bias but close to center — safe default
    return resized.crop((left, top, left + target_w, top + target_h))


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
) -> int:
    """Place rows of photos on the canvas. Returns y position after last row."""
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
            cropped = crop_to_fill(photos[photo_idx], widths[col_idx], row_h)
            canvas.paste(cropped, (x, y))
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


def generate_collage(
    photo_paths: list[str],
    output_path: str,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    logo_path: str | None = None,
    seed: int | None = None,
) -> str:
    """Generate a masonry collage with branded center strip.

    Layout:
        - Top photo rows (5 photos)
        - Branded strip (event name, org/venue, logo) — impossible to crop out
        - Bottom photo rows (5 photos, ends strong)
    """
    rng = random.Random(seed)

    all_photos = [Image.open(p) for p in photo_paths]
    n = len(all_photos)

    # Split photos: top half and bottom half
    top_count = n // 2
    bottom_count = n - top_count
    top_photos = all_photos[:top_count]
    bottom_photos = all_photos[top_count:]

    # Select patterns that match photo counts
    valid_top = [p for p in TOP_PATTERNS if sum(p) == top_count]
    valid_bottom = [p for p in BOTTOM_PATTERNS if sum(p) == bottom_count]

    if not valid_top:
        valid_top = [[top_count]]
    if not valid_bottom:
        valid_bottom = [[bottom_count]]

    top_pattern = rng.choice(valid_top)
    bottom_pattern = rng.choice(valid_bottom)

    # Calculate heights
    top_gaps = (len(top_pattern) - 1) * GAP
    bottom_gaps = (len(bottom_pattern) - 1) * GAP
    photo_area_h = CANVAS_H - STRIP_H - GAP  # gap between top photos and strip
    top_h = int(photo_area_h * 0.50)
    bottom_h = photo_area_h - top_h

    # Get photo tint for cream coloring
    photo_tint = get_photo_tint(all_photos)

    # Tint the gap color
    gap_color = (
        (STRIP_CREAM[0] * 2 + photo_tint[0]) // 3,
        (STRIP_CREAM[1] * 2 + photo_tint[1]) // 3,
        (STRIP_CREAM[2] * 2 + photo_tint[2]) // 3,
    )

    # Create canvas with tinted cream background
    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), gap_color)

    # Place top photos
    y = 0
    y = place_photo_rows(canvas, top_photos, top_pattern, y, top_h, rng)

    # Draw branded center strip
    strip_y = y - GAP  # overlap the last gap
    canvas = draw_branded_strip(
        canvas, strip_y, event_name, org, venue, logo_path, photo_tint
    )

    # Place bottom photos
    bottom_y = strip_y + STRIP_H
    place_photo_rows(
        canvas, bottom_photos, bottom_pattern, bottom_y, bottom_h, rng
    )

    # Save
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas_rgb = canvas.convert("RGB") if canvas.mode != "RGB" else canvas
    canvas_rgb.save(str(output), "PNG", quality=95)

    print(f"Collage generated: {output} ({CANVAS_W}x{CANVAS_H}, "
          f"top={top_pattern}, bottom={bottom_pattern})")
    return str(output)


def main():
    parser = argparse.ArgumentParser(description="Generate a masonry collage")
    parser.add_argument("--photos", nargs="+", required=True)
    parser.add_argument("--event", default="", help="Event name")
    parser.add_argument("--org", default="", help="Organization")
    parser.add_argument("--venue", default="", help="Venue")
    parser.add_argument("--logo", default=None, help="Path to DW logo")
    parser.add_argument("--output", default="output/collage.png")
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args()

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
