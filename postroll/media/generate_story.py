"""
PostRoll — Story Template Generator

Creates a 1080x1920 Instagram/Facebook story image from a photo
with blurred background, event details, and DW Photography branding.

Usage:
    python generate_story.py --photo path/to/photo.jpg \
        --event "Sing Play" \
        --org "DCINY" \
        --venue "Carnegie Hall" \
        --output output/story.png
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont


# === Design Tokens ===

CANVAS_W = 1080
CANVAS_H = 1920

# Rose gold divider
ROSE_GOLD = (196, 135, 122)  # #C4877A

# Text colors
TEXT_WHITE = (255, 255, 255)  # title (on blurred background)
TEXT_DARK = (60, 55, 50)  # org/venue (on cream overlay)
ROSE_GOLD_DARK = (160, 105, 95)  # divider on cream background

# Layout — title above photo, generous spacing
EVENT_NAME_Y = 130  # script title — breathing room from top
PHOTO_TOP_Y = 260  # tighter to title (~50px gap after text)
PHOTO_SIDE_MARGIN = 20
PHOTO_BOTTOM_Y = 1280  # larger photo area (~1020px tall)
DIVIDER_Y = 1360  # 80px below photo
DIVIDER_THICKNESS = 2
DIVIDER_MARGIN = 200  # inset from each side
ORG_VENUE_Y = 1420  # 60px below divider
ORG_VENUE_LINE_SPACING = 60  # generous line height
LOGO_BOTTOM_MARGIN = 100

# Background blur
BG_BLUR_RADIUS = 40
BG_DARKEN_OPACITY = 70  # lighter overlay, let warm tones show through

# Fonts (macOS system fonts)
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"
FONT_DETAIL_INDEX = 12  # Thin weight


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    """Load a font, falling back to default if not found."""
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        print(f"Warning: Could not load font {path}, using default")
        return ImageFont.load_default()


def create_blurred_background(photo: Image.Image) -> Image.Image:
    """Create a blurred, darkened, full-canvas background from the photo."""
    # Scale photo to fill canvas (cover mode)
    photo_ratio = photo.width / photo.height
    canvas_ratio = CANVAS_W / CANVAS_H

    if photo_ratio > canvas_ratio:
        # Photo is wider — scale to canvas height, crop sides
        scale = CANVAS_H / photo.height
    else:
        # Photo is taller — scale to canvas width, crop top/bottom
        scale = CANVAS_W / photo.width

    new_w = int(photo.width * scale)
    new_h = int(photo.height * scale)
    bg = photo.resize((new_w, new_h), Image.LANCZOS)

    # Center crop to canvas size
    left = (new_w - CANVAS_W) // 2
    top = (new_h - CANVAS_H) // 2
    bg = bg.crop((left, top, left + CANVAS_W, top + CANVAS_H))

    # Blur
    bg = bg.filter(ImageFilter.GaussianBlur(radius=BG_BLUR_RADIUS))

    # Light darken over the full canvas for cohesion
    darken = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, BG_DARKEN_OPACITY))
    bg = bg.convert("RGBA")
    bg = Image.alpha_composite(bg, darken)

    # Semi-transparent cream overlay on the lower section (below photo)
    # Gradient transition from transparent to cream across ~100px
    overlay = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    cream = (252, 250, 247)  # near-white, slight warmth
    cream_opacity = 235  # almost fully opaque for clean white look

    transition_start = PHOTO_BOTTOM_Y + 20  # start fading in just below photo
    transition_end = transition_start + 100  # fully opaque over 100px

    for y_pos in range(transition_start, CANVAS_H):
        if y_pos < transition_end:
            # Gradient zone
            progress = (y_pos - transition_start) / (transition_end - transition_start)
            alpha = int(cream_opacity * progress)
        else:
            alpha = cream_opacity
        row = Image.new("RGBA", (CANVAS_W, 1), (*cream, alpha))
        overlay.paste(row, (0, y_pos))

    bg = Image.alpha_composite(bg, overlay)

    # Subtle gradient at top for title readability
    for y_pos in range(0, 200):
        alpha = int(50 * (1 - y_pos / 200))  # fades from 50 to 0
        row = Image.new("RGBA", (CANVAS_W, 1), (0, 0, 0, alpha))
        overlay_top = Image.new("RGBA", (CANVAS_W, 1), (0, 0, 0, 0))
        overlay_top = Image.alpha_composite(overlay_top, row)
        bg.paste(overlay_top, (0, y_pos), overlay_top)

    return bg


def place_photo(canvas: Image.Image, photo: Image.Image) -> Image.Image:
    """Place the original photo in the upper portion of the canvas."""
    # Available area for the photo
    avail_w = CANVAS_W - (2 * PHOTO_SIDE_MARGIN)
    avail_h = PHOTO_BOTTOM_Y - PHOTO_TOP_Y

    # Scale photo to fit within available area, maintaining aspect ratio
    photo_ratio = photo.width / photo.height
    avail_ratio = avail_w / avail_h

    if photo_ratio > avail_ratio:
        # Photo is wider than available area — fit to width
        new_w = avail_w
        new_h = int(avail_w / photo_ratio)
    else:
        # Photo is taller — fit to height
        new_h = avail_h
        new_w = int(avail_h * photo_ratio)

    resized = photo.resize((new_w, new_h), Image.LANCZOS)

    # Center horizontally, vertically within the photo area
    x = (CANVAS_W - new_w) // 2
    y = PHOTO_TOP_Y + (avail_h - new_h) // 2

    # Paste photo directly — no border, no shadow
    resized_rgba = resized.convert("RGBA")
    canvas.paste(resized_rgba, (x, y), resized_rgba)

    return canvas


def draw_divider(draw: ImageDraw.ImageDraw):
    """Draw the rose-gold divider line."""
    x1 = DIVIDER_MARGIN
    x2 = CANVAS_W - DIVIDER_MARGIN
    y = DIVIDER_Y
    draw.line([(x1, y), (x2, y)], fill=ROSE_GOLD_DARK, width=DIVIDER_THICKNESS)


def draw_title(canvas: Image.Image, event_name: str):
    """Draw the event name with a subtle drop shadow for depth."""
    event_font = load_font(FONT_SCRIPT, 100)
    tmp_draw = ImageDraw.Draw(canvas)
    bbox = tmp_draw.textbbox((0, 0), event_name, font=event_font)
    text_w = bbox[2] - bbox[0]
    x = (CANVAS_W - text_w) // 2

    # Drop shadow on a separate layer
    shadow = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.text((x + 3, EVENT_NAME_Y + 4), event_name, font=event_font, fill=(0, 0, 0, 100))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=6))

    canvas_rgba = canvas.convert("RGBA")
    canvas_rgba = Image.alpha_composite(canvas_rgba, shadow)

    # Main text
    draw = ImageDraw.Draw(canvas_rgba)
    draw.text((x, EVENT_NAME_Y), event_name, font=event_font, fill=TEXT_WHITE)

    return canvas_rgba


def draw_text(draw: ImageDraw.ImageDraw, org: str, venue: str):
    """Draw org/venue text."""

    # Org and Venue — Helvetica Neue Thin, wide spacing, on separate lines
    venue_font = load_font(FONT_DETAIL, 38, index=FONT_DETAIL_INDEX)
    line_spacing = ORG_VENUE_LINE_SPACING
    spacing = 8  # extra pixels between characters for tracking

    for i, line_text in enumerate([org, venue]):
        y = ORG_VENUE_Y + (i * line_spacing)

        # Calculate total width with letter spacing
        total_w = 0
        for ch in line_text:
            ch_bbox = draw.textbbox((0, 0), ch, font=venue_font)
            total_w += (ch_bbox[2] - ch_bbox[0]) + spacing
        total_w -= spacing

        # Draw centered
        x = (CANVAS_W - total_w) // 2
        for ch in line_text:
            draw.text((x, y), ch, font=venue_font, fill=TEXT_DARK)
            ch_bbox = draw.textbbox((0, 0), ch, font=venue_font)
            x += (ch_bbox[2] - ch_bbox[0]) + spacing


def place_logo(canvas: Image.Image, logo_path: str | None):
    """Place the DW Photography logo at the bottom center."""
    if not logo_path or not Path(logo_path).exists():
        # Draw placeholder text if no logo file
        draw = ImageDraw.Draw(canvas)
        font = load_font(FONT_AVENIR, 20, index=0)
        text = "DW / DAN WRIGHT PHOTOGRAPHY"
        bbox = draw.textbbox((0, 0), text, font=font)
        text_w = bbox[2] - bbox[0]
        x = (CANVAS_W - text_w) // 2
        y = CANVAS_H - LOGO_BOTTOM_MARGIN
        draw.text((x, y), text, font=font, fill=(*TEXT_DARK, 200))
        return canvas

    logo = Image.open(logo_path).convert("RGBA")

    # Scale logo to prominent width (~60% of canvas)
    logo_target_w = 650
    scale = logo_target_w / logo.width
    logo = logo.resize(
        (int(logo.width * scale), int(logo.height * scale)),
        Image.LANCZOS,
    )

    # Center horizontally, near bottom
    x = (CANVAS_W - logo.width) // 2
    y = CANVAS_H - LOGO_BOTTOM_MARGIN - logo.height

    canvas.paste(logo, (x, y), logo)
    return canvas


def generate_story(
    photo_path: str,
    event_name: str,
    org: str,
    venue: str,
    output_path: str,
    logo_path: str | None = None,
) -> str:
    """Generate a story template image.

    Args:
        photo_path: Path to the source photo
        event_name: Name of the event (e.g., "Sing Play")
        org: Organization name (e.g., "DCINY")
        venue: Venue name (e.g., "Carnegie Hall")
        output_path: Where to save the output PNG
        logo_path: Optional path to the DW Photography logo (white version)

    Returns:
        Path to the generated image
    """
    photo = Image.open(photo_path)

    # 1. Create blurred background
    canvas = create_blurred_background(photo)

    # 2. Place original photo
    canvas = place_photo(canvas, photo)

    # 3. Draw title with shadow (returns new RGBA canvas)
    canvas = draw_title(canvas, event_name)

    # 4. Draw divider and org/venue text
    draw = ImageDraw.Draw(canvas)
    draw_divider(draw)
    draw_text(draw, org, venue)

    # 5. Place logo
    canvas = place_logo(canvas, logo_path)

    # 5. Save
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas = canvas.convert("RGB")
    canvas.save(str(output), "PNG", quality=95)

    print(f"Story generated: {output} ({CANVAS_W}x{CANVAS_H})")
    return str(output)


def main():
    parser = argparse.ArgumentParser(description="Generate a story template image")
    parser.add_argument("--photo", required=True, help="Path to source photo")
    parser.add_argument("--event", required=True, help="Event name")
    parser.add_argument("--org", required=True, help="Organization name")
    parser.add_argument("--venue", required=True, help="Venue name")
    parser.add_argument("--output", default="output/story.png", help="Output path")
    parser.add_argument("--logo", default=None, help="Path to DW logo (white PNG)")
    args = parser.parse_args()

    generate_story(
        photo_path=args.photo,
        event_name=args.event,
        org=args.org,
        venue=args.venue,
        output_path=args.output,
        logo_path=args.logo,
    )


if __name__ == "__main__":
    main()
