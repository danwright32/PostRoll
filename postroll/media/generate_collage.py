"""
PostRoll — Masonry Collage Generator

Creates a 1080x1920 masonry-style collage from 10 photos.
Used for: Wednesday collage story.

The layout is algorithmic based on photo orientations (landscape/portrait mix).
Photos are arranged in rows of varying sizes with thin gaps.

Usage:
    python generate_collage.py \
        --photos photo1.jpg photo2.jpg ... photo10.jpg \
        --output output/collage.png
"""

from __future__ import annotations

import argparse
import random
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


# === Design Tokens ===

CANVAS_W = 1080
CANVAS_H = 1920

GAP = 5  # thin gap between photos
OUTER_MARGIN = 4  # margin around entire collage
LOGO_WIDTH = 120  # small watermark
LOGO_MARGIN = 15
LOGO_OPACITY = 160  # semi-transparent

# Background — warm cream matching the brand (not black)
BG_COLOR = (240, 235, 228)  # warm cream visible in gaps and margins

# Row layout patterns for 10 photos (numbers = photos per row)
# Multiple patterns for variety — selected randomly
LAYOUT_PATTERNS = [
    [1, 3, 2, 3, 1],       # hero → trio → pair → trio → hero
    [2, 1, 3, 1, 3],       # pair → hero → trio → hero → trio
    [1, 2, 3, 2, 2],       # hero → pair → trio → pair → pair
    [3, 1, 2, 1, 3],       # trio → hero → pair → hero → trio
    [2, 3, 2, 1, 2],       # pair → trio → pair → hero → pair
    [1, 2, 2, 3, 2],       # hero → pair → pair → trio → pair
]



def load_and_classify_photos(photo_paths: list[str]) -> list[tuple[Image.Image, str]]:
    """Load photos and classify as landscape or portrait."""
    result = []
    for path in photo_paths:
        img = Image.open(path)
        orientation = "landscape" if img.width >= img.height else "portrait"
        result.append((img, orientation))
    return result


def calculate_row_heights(
    pattern: list[int],
    photos: list[tuple[Image.Image, str]],
    total_h: int,
) -> list[int]:
    """Calculate row heights based on actual photo aspect ratios.

    For each row, compute the natural height if photos are fit side-by-side
    at that row width. Then scale all rows proportionally to fit the canvas.
    This minimizes cropping.
    """
    total_gaps_v = (len(pattern) - 1) * GAP
    avail_h = total_h - total_gaps_v - 2 * OUTER_MARGIN

    # Calculate natural height for each row
    natural_heights = []
    photo_idx = 0
    for photos_in_row in pattern:
        row_gaps = (photos_in_row - 1) * GAP
        avail_w = CANVAS_W - 2 * OUTER_MARGIN - row_gaps

        # Get aspect ratios of photos in this row
        ratios = []
        for j in range(photos_in_row):
            img, _ = photos[photo_idx + j]
            ratios.append(img.width / img.height)

        # Natural row height: all photos fit side-by-side at their aspect ratios
        # Each photo width = ratio * row_height, sum of widths = avail_w
        # So: row_height * sum(ratios) = avail_w → row_height = avail_w / sum(ratios)
        natural_h = avail_w / sum(ratios)
        natural_heights.append(natural_h)

        photo_idx += photos_in_row

    # Scale all rows proportionally to fit canvas
    total_natural = sum(natural_heights)
    scale = avail_h / total_natural

    heights = [int(h * scale) for h in natural_heights]

    # Fix rounding
    used = sum(heights) + total_gaps_v
    heights[-1] += (total_h - used)

    return heights


def crop_to_fill(photo: Image.Image, target_w: int, target_h: int) -> Image.Image:
    """Crop and resize photo to fill target dimensions.

    Biases vertical crop toward the top (keeps heads/faces visible)
    and centers horizontal crop.
    """
    photo_ratio = photo.width / photo.height
    target_ratio = target_w / target_h

    if photo_ratio > target_ratio:
        # Photo is wider — scale to target height, crop sides (centered)
        scale = target_h / photo.height
    else:
        # Photo is taller — scale to target width, crop top/bottom
        scale = target_w / photo.width

    new_w = int(photo.width * scale)
    new_h = int(photo.height * scale)
    resized = photo.resize((new_w, new_h), Image.LANCZOS)

    # Horizontal: center crop
    left = (new_w - target_w) // 2
    # Vertical: bias toward top — keep upper 30% anchor point instead of 50%
    overflow = new_h - target_h
    top = int(overflow * 0.3)  # keeps more of the top where heads are

    return resized.crop((left, top, left + target_w, top + target_h))


def generate_collage(
    photo_paths: list[str],
    output_path: str,
    logo_path: str | None = None,
    seed: int | None = None,
) -> str:
    """Generate a masonry collage from photos.

    Args:
        photo_paths: List of paths to photos (ideally 10)
        output_path: Where to save the output PNG
        logo_path: Optional path to DW Photography logo (white version)
        seed: Optional random seed for reproducible layout selection

    Returns:
        Path to the generated image
    """
    if seed is not None:
        random.seed(seed)

    photos = load_and_classify_photos(photo_paths)
    n = len(photos)

    # Select a layout pattern that sums to our photo count
    valid_patterns = [p for p in LAYOUT_PATTERNS if sum(p) == n]
    if not valid_patterns:
        # Fallback: generate a simple pattern
        valid_patterns = [_generate_fallback_pattern(n)]

    pattern = random.choice(valid_patterns)
    row_heights = calculate_row_heights(pattern, photos, CANVAS_H)

    # Create canvas with warm cream background (gaps and margins show through)
    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), BG_COLOR)

    # Place photos row by row, inset by outer margin
    photo_idx = 0
    y = OUTER_MARGIN
    inner_w = CANVAS_W - 2 * OUTER_MARGIN

    for row_idx, photos_in_row in enumerate(pattern):
        row_h = row_heights[row_idx]
        total_gaps_in_row = (photos_in_row - 1) * GAP
        avail_w = inner_w - total_gaps_in_row

        # Divide width among photos in this row
        # For variety, use slight random variation in widths for rows of 2+
        if photos_in_row == 1:
            widths = [avail_w]
        elif photos_in_row == 2:
            # Intentional asymmetry — clearly designed, not accidental
            split = random.choice([0.56, 0.44, 0.58, 0.42, 0.55, 0.45])
            w1 = int(avail_w * split)
            w2 = avail_w - w1
            widths = [w1, w2]
        elif photos_in_row == 3:
            # Varied trios — one photo dominates or balanced
            splits = random.choice([
                (0.40, 0.30, 0.30),
                (0.30, 0.40, 0.30),
                (0.30, 0.30, 0.40),
                (0.45, 0.28, 0.27),
                (0.27, 0.28, 0.45),
            ])
            w1 = int(avail_w * splits[0])
            w2 = int(avail_w * splits[1])
            w3 = avail_w - w1 - w2
            widths = [w1, w2, w3]
        else:
            base_w = avail_w // photos_in_row
            widths = [base_w] * photos_in_row
            widths[-1] = avail_w - base_w * (photos_in_row - 1)

        x = OUTER_MARGIN
        for col_idx in range(photos_in_row):
            photo, orientation = photos[photo_idx]
            cell_w = widths[col_idx]
            cell_h = row_h

            # Crop photo to fill cell
            cropped = crop_to_fill(photo, cell_w, cell_h)
            canvas.paste(cropped, (x, y))

            x += cell_w + GAP
            photo_idx += 1

        y += row_h + GAP

    # Logo watermark (bottom-right corner, semi-transparent)
    if logo_path and Path(logo_path).exists():
        logo = Image.open(logo_path).convert("RGBA")
        scale = LOGO_WIDTH / logo.width
        logo = logo.resize(
            (int(logo.width * scale), int(logo.height * scale)),
            Image.LANCZOS,
        )

        # Reduce opacity
        alpha = logo.split()[3]
        alpha = alpha.point(lambda p: int(p * LOGO_OPACITY / 255))
        logo.putalpha(alpha)

        lx = CANVAS_W - LOGO_MARGIN - logo.width
        ly = CANVAS_H - LOGO_MARGIN - logo.height

        # Paste onto canvas
        canvas_rgba = canvas.convert("RGBA")
        canvas_rgba.paste(logo, (lx, ly), logo)
        canvas = canvas_rgba.convert("RGB")

    # Save
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(str(output), "PNG", quality=95)

    print(f"Collage generated: {output} ({CANVAS_W}x{CANVAS_H}, pattern={pattern})")
    return str(output)


def _generate_fallback_pattern(n: int) -> list[int]:
    """Generate a simple row pattern for any number of photos."""
    pattern = []
    remaining = n
    while remaining > 0:
        if remaining >= 3:
            row = random.choice([1, 2, 3])
        elif remaining == 2:
            row = 2
        else:
            row = 1
        row = min(row, remaining)
        pattern.append(row)
        remaining -= row
    return pattern


def main():
    parser = argparse.ArgumentParser(description="Generate a masonry collage")
    parser.add_argument(
        "--photos", nargs="+", required=True, help="Paths to photos"
    )
    parser.add_argument("--logo", default=None, help="Path to DW logo (white PNG)")
    parser.add_argument(
        "--output", default="output/collage.png", help="Output path"
    )
    parser.add_argument("--seed", type=int, default=None, help="Random seed")
    args = parser.parse_args()

    generate_collage(
        photo_paths=args.photos,
        output_path=args.output,
        logo_path=args.logo,
        seed=args.seed,
    )


if __name__ == "__main__":
    main()
