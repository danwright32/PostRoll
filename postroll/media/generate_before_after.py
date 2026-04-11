"""
PostRoll — Before/After Image Generator

Creates a 1080x1920 before/after comparison image from a RAW and edited photo.
Used for: Tuesday reel closing frame, Friday before/after story.

Design approach: Uses the same visual vocabulary as the story template —
blurred photo background with cream/white label strips for text areas.
The photos are the hero; the design gets out of the way.

Usage:
    python generate_before_after.py \
        --raw path/to/raw.jpg \
        --edit path/to/edited.jpg \
        --output output/before_after.png
"""

from __future__ import annotations

import argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont


# === Design Tokens (shared with story template) ===

CANVAS_W = 1080
CANVAS_H = 1920

# Colors — matching story template palette
CREAM = (252, 250, 247)  # same as story template lower section
CREAM_OPACITY = 185  # lower opacity lets blurred photo warmth show through
TEXT_DARK = (60, 55, 50)  # same as story template org/venue text
ROSE_GOLD = (160, 105, 95)  # divider — same as story template

# Layout
DIVIDER_H = 2
LABEL_FONT_SIZE = 28
LABEL_LETTER_SPACING = 8
LABEL_MARGIN = 20  # distance from photo edge
MID_STRIP_H = 55  # cream strip between photos with "Edit" label
LOGO_WIDTH = 280
BOTTOM_CREAM_H = 130  # taller bottom to balance the top

# Fonts (same as story template)
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"
FONT_DETAIL_THIN = 12

# Background
BG_BLUR_RADIUS = 60  # heavy blur — smooth color wash, not muddy detail
BG_DARKEN_OPACITY = 30  # minimal darkening to preserve warm tones


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        print(f"Warning: Could not load font {path}, using default")
        return ImageFont.load_default()


def draw_spaced_text_centered(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    fill: tuple,
    center_x: int,
    y: int,
    spacing: int = LABEL_LETTER_SPACING,
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


def create_blurred_background(photo: Image.Image) -> Image.Image:
    """Create a blurred background from a photo."""
    photo_ratio = photo.width / photo.height
    canvas_ratio = CANVAS_W / CANVAS_H

    if photo_ratio > canvas_ratio:
        scale = CANVAS_H / photo.height
    else:
        scale = CANVAS_W / photo.width

    new_w = int(photo.width * scale)
    new_h = int(photo.height * scale)
    bg = photo.resize((new_w, new_h), Image.LANCZOS)

    left = (new_w - CANVAS_W) // 2
    top = (new_h - CANVAS_H) // 2
    bg = bg.crop((left, top, left + CANVAS_W, top + CANVAS_H))
    bg = bg.filter(ImageFilter.GaussianBlur(radius=BG_BLUR_RADIUS))

    # Check average brightness — if dark, brighten the blur
    bg_rgb = bg.convert("RGB")
    pixels = list(bg_rgb.resize((50, 50), Image.LANCZOS).getdata())
    avg_brightness = sum(p[0] * 0.299 + p[1] * 0.587 + p[2] * 0.114 for p in pixels) / len(pixels)

    bg = bg.convert("RGBA")
    if avg_brightness < 80:
        # Dark photo — lighten heavily so cream tinting looks warm, not muddy
        brighten = Image.new("RGBA", (CANVAS_W, CANVAS_H), (255, 255, 255, 160))
        bg = Image.alpha_composite(bg, brighten)
    elif avg_brightness < 130:
        # Medium photo — lighten moderately
        brighten = Image.new("RGBA", (CANVAS_W, CANVAS_H), (255, 255, 255, 80))
        bg = Image.alpha_composite(bg, brighten)

    darken = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, BG_DARKEN_OPACITY))
    bg = Image.alpha_composite(bg, darken)

    return bg


def apply_cream_strip(canvas: Image.Image, y: int, h: int) -> Image.Image:
    """Apply a cream/white strip at the given position (same style as story template)."""
    strip = Image.new("RGBA", (CANVAS_W, h), (*CREAM, CREAM_OPACITY))
    canvas.paste(strip, (0, y), strip)
    return canvas


def fit_photo(photo: Image.Image, avail_w: int, max_h: int) -> Image.Image:
    """Fit photo to width, maintaining aspect ratio, capping at max height."""
    ratio = photo.width / photo.height
    new_w = avail_w
    new_h = int(avail_w / ratio)

    if new_h > max_h:
        new_h = max_h
        new_w = int(max_h * ratio)

    return photo.resize((new_w, new_h), Image.LANCZOS)


def draw_header(
    canvas: Image.Image,
    event_name: str,
    org: str,
    venue: str,
    header_h: int,
) -> Image.Image:
    """Draw cream header area with event name, org, and venue.
    Matches the story template's lower section design vocabulary.
    """
    # Apply cream overlay to header area
    canvas = apply_cream_strip(canvas, 0, header_h)
    draw = ImageDraw.Draw(canvas)

    # Event name — SignPainter script, dark text on cream
    title_font = load_font(FONT_SCRIPT, 90)
    bbox = draw.textbbox((0, 0), event_name, font=title_font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    tx = (CANVAS_W - text_w) // 2

    # Vertical layout: title centered in upper portion, org/venue below
    content_h = text_h + 50 + 30 + 30  # title + gap + org line + venue line
    start_y = (header_h - content_h) // 2

    draw.text((tx, start_y), event_name, font=title_font, fill=TEXT_DARK)

    # Org and venue — Helvetica Neue Thin with spacing
    detail_font = load_font(FONT_DETAIL, 30, index=FONT_DETAIL_THIN)
    org_venue_y = start_y + text_h + 45

    for i, line in enumerate([org, venue]):
        y = org_venue_y + i * 42
        draw_spaced_text_centered(draw, line, detail_font, TEXT_DARK, CANVAS_W // 2, y)

    # Rose-gold divider at bottom of header
    draw.line(
        [(200, header_h - 2), (CANVAS_W - 200, header_h - 2)],
        fill=ROSE_GOLD, width=DIVIDER_H,
    )

    return canvas


def generate_before_after(
    raw_path: str,
    edit_path: str,
    output_path: str,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    logo_path: str | None = None,
    raw_label_color: str = "light",  # "light" or "dark"
    raw_label_pos: str = "left",  # "left" or "right"
    edit_label_color: str = "light",
    edit_label_pos: str = "left",
) -> str:
    """Generate a before/after comparison image.

    Layout (top to bottom):
        - Cream header (event name, org, venue — matching story template)
        - "RAW" label strip
        - RAW photo (fit to width, uncropped)
        - "Edit" label strip
        - Edited photo (fit to width, uncropped)
        - Bottom area with logo
    """
    raw_photo = Image.open(raw_path)
    edit_photo = Image.open(edit_path)
    label_font = load_font(FONT_DETAIL, LABEL_FONT_SIZE, index=FONT_DETAIL_THIN)
    title_font = load_font(FONT_SCRIPT, 90)
    detail_font = load_font(FONT_DETAIL, 30, index=FONT_DETAIL_THIN)

    # Create blurred background
    canvas = create_blurred_background(edit_photo)

    # Calculate photo sizes (fit to width, uncropped)
    raw_resized = fit_photo(raw_photo, CANVAS_W, CANVAS_H)
    edit_resized = fit_photo(edit_photo, CANVAS_W, CANVAS_H)
    total_photo_h = raw_resized.height + edit_resized.height

    # Fixed header height — consistent across all events
    header_cream_h = 280

    draw_tmp = ImageDraw.Draw(canvas)
    title_bbox = draw_tmp.textbbox((0, 0), event_name, font=title_font)
    title_h = title_bbox[3] - title_bbox[1]

    # Remaining space after photos + dividers + mid strip goes to header and footer
    fixed_chrome = DIVIDER_H * 2 + MID_STRIP_H
    remaining = CANVAS_H - total_photo_h - fixed_chrome

    # Header gets what it needs, footer gets the rest
    footer_cream_h = max(BOTTOM_CREAM_H, remaining - header_cream_h)
    # If header + footer > remaining, scale header down
    if header_cream_h + footer_cream_h > remaining:
        footer_cream_h = BOTTOM_CREAM_H
        header_cream_h = remaining - footer_cream_h

    y = 0

    # === CREAM HEADER: title, org, venue (starts at top edge) ===
    canvas = apply_cream_strip(canvas, 0, header_cream_h)
    draw = ImageDraw.Draw(canvas)

    # Fixed positions within header for consistency
    tw = title_bbox[2] - title_bbox[0]
    tx = (CANVAS_W - tw) // 2
    title_y = 35  # fixed top padding
    draw.text((tx, title_y), event_name, font=title_font, fill=TEXT_DARK)

    info_y = title_y + 110  # fixed distance from title top to org/venue
    for j, line in enumerate([org, venue]):
        if line:
            draw_spaced_text_centered(draw, line, detail_font, TEXT_DARK, CANVAS_W // 2, info_y + j * 42)

    y = header_cream_h

    # === ROSE-GOLD DIVIDER (header → photos) ===
    draw.line([(0, y), (CANVAS_W, y)], fill=ROSE_GOLD, width=DIVIDER_H)
    y += DIVIDER_H

    # === PHOTOS with configurable labels ===
    label_configs = [
        (raw_resized, "RAW", raw_label_color, raw_label_pos),
        (edit_resized, "Edit", edit_label_color, edit_label_pos),
    ]

    for i, (photo_resized, label_text, label_color, label_pos) in enumerate(label_configs):
        px = (CANVAS_W - photo_resized.width) // 2
        canvas.paste(photo_resized.convert("RGBA"), (px, y), photo_resized.convert("RGBA"))

        # Draw label on the photo
        draw = ImageDraw.Draw(canvas)
        fill = (255, 255, 255) if label_color == "light" else TEXT_DARK
        shadow_fill = (0, 0, 0, 140) if label_color == "light" else (255, 255, 255, 100)

        if label_pos == "left":
            lx = px + LABEL_MARGIN
        else:
            # Calculate text width for right alignment
            total_w = 0
            for ch in label_text:
                bbox = draw.textbbox((0, 0), ch, font=label_font)
                total_w += (bbox[2] - bbox[0]) + LABEL_LETTER_SPACING
            total_w -= LABEL_LETTER_SPACING
            lx = px + photo_resized.width - LABEL_MARGIN - total_w

        ly = y + LABEL_MARGIN

        # Shadow for readability
        shadow_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow_layer)
        sx = lx
        for ch in label_text:
            sd.text((sx + 2, ly + 2), ch, font=label_font, fill=shadow_fill)
            bbox_ch = sd.textbbox((0, 0), ch, font=label_font)
            sx += (bbox_ch[2] - bbox_ch[0]) + LABEL_LETTER_SPACING
        shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=3))
        canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow_layer)

        # Main text
        draw = ImageDraw.Draw(canvas)
        tx = lx
        for ch in label_text:
            draw.text((tx, ly), ch, font=label_font, fill=fill)
            bbox_ch = draw.textbbox((0, 0), ch, font=label_font)
            tx += (bbox_ch[2] - bbox_ch[0]) + LABEL_LETTER_SPACING

        y += photo_resized.height

        # Mid-strip between photos
        if i == 0:
            canvas = apply_cream_strip(canvas, y, MID_STRIP_H)
            y += MID_STRIP_H

    # === ROSE-GOLD DIVIDER (photos → footer) ===
    draw = ImageDraw.Draw(canvas)
    draw.line([(0, y), (CANVAS_W, y)], fill=ROSE_GOLD, width=DIVIDER_H)
    y += DIVIDER_H

    # === BOTTOM CREAM: logo (extends to bottom edge) ===
    canvas = apply_cream_strip(canvas, y, footer_cream_h)
    if logo_path and Path(logo_path).exists():
        logo = Image.open(logo_path).convert("RGBA")
        logo_scale = LOGO_WIDTH / logo.width
        logo = logo.resize(
            (int(logo.width * logo_scale), int(logo.height * logo_scale)),
            Image.LANCZOS,
        )
        lx = (CANVAS_W - logo.width) // 2
        ly = y + (footer_cream_h - logo.height) // 2
        canvas.paste(logo, (lx, ly), logo)

    # Save
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas = canvas.convert("RGB")
    canvas.save(str(output), "PNG", quality=95)

    print(f"Before/after generated: {output} ({CANVAS_W}x{CANVAS_H})")
    return str(output)


def main():
    parser = argparse.ArgumentParser(
        description="Generate a before/after comparison image"
    )
    parser.add_argument("--raw", required=True, help="Path to RAW/unedited photo")
    parser.add_argument("--edit", required=True, help="Path to edited photo")
    parser.add_argument("--event", default="", help="Event name")
    parser.add_argument("--org", default="", help="Organization name")
    parser.add_argument("--venue", default="", help="Venue name")
    parser.add_argument("--logo", default=None, help="Path to DW logo")
    parser.add_argument("--raw-label-color", default="light", choices=["light", "dark"])
    parser.add_argument("--raw-label-pos", default="left", choices=["left", "right"])
    parser.add_argument("--edit-label-color", default="light", choices=["light", "dark"])
    parser.add_argument("--edit-label-pos", default="left", choices=["left", "right"])
    parser.add_argument(
        "--output", default="output/before_after.png", help="Output path"
    )
    args = parser.parse_args()

    generate_before_after(
        raw_path=args.raw,
        edit_path=args.edit,
        output_path=args.output,
        event_name=args.event,
        org=args.org,
        venue=args.venue,
        logo_path=args.logo,
        raw_label_color=args.raw_label_color,
        raw_label_pos=args.raw_label_pos,
        edit_label_color=args.edit_label_color,
        edit_label_pos=args.edit_label_pos,
    )


if __name__ == "__main__":
    main()
