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
PHOTO_BOTTOM_Y = 1450  # larger photo area (~1190px tall)
ORG_VENUE_Y = 1530  # in the cream caption band below the photo
ORG_VENUE_LINE_SPACING = 55  # slightly tighter line height
LOGO_BOTTOM_MARGIN = 100

# Background blur
BG_BLUR_RADIUS = 40
BG_DARKEN_OPACITY = 70  # lighter overlay, let warm tones show through

# Fonts (macOS system fonts)
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"
FONT_DETAIL_INDEX = 7  # Light weight (Thin rendered spindly)
FONT_DETAIL_LIGHT = FONT_DETAIL_INDEX  # alias for the cross-template alignment tests


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
    cream_opacity = 255  # fully opaque — blocks warm bleed from stage lighting

    transition_start = PHOTO_BOTTOM_Y  # start fading in right at photo area bottom
    transition_end = transition_start + 80  # fully opaque over 80px

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


def place_photo(canvas: Image.Image, photo: Image.Image) -> tuple[Image.Image, int]:
    """Place the original photo in the upper portion of the canvas.
    Returns (canvas, actual_photo_top_y) so callers can layout against the
    photo's real top edge instead of the wider available band."""
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

    # Drop shadow — soft cast behind the photo so it lifts off the background
    shadow_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    shadow_rect = Image.new("RGBA", (new_w + 16, new_h + 16), (0, 0, 0, 160))
    shadow_layer.paste(shadow_rect, (x - 8, y + 2))  # slight downward offset
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=22))
    canvas = Image.alpha_composite(canvas, shadow_layer)

    # Thin cream border — bright edge against the dark bg creates clear separation
    border_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    bd = ImageDraw.Draw(border_layer)
    bd.rectangle(
        [x - 2, y - 2, x + new_w + 1, y + new_h + 1],
        outline=(252, 250, 247, 180),  # cream, semi-transparent
        width=2,
    )
    canvas = Image.alpha_composite(canvas, border_layer)

    # Paste photo on top
    resized_rgba = resized.convert("RGBA")
    canvas.paste(resized_rgba, (x, y), resized_rgba)

    return canvas, y


def _fit_script_title(
    event_name: str,
    canvas: Image.Image,
    max_width: int,
    max_size: int = 110,
    min_size: int = 64,
) -> tuple[list[str], ImageFont.FreeTypeFont]:
    """Pick a layout for `event_name` that fits in `max_width`.

    Preference order:
      1. Single line at `max_size` if it fits.
      2. Two balanced lines at `max_size` — split at the word boundary that
         minimises max(line1_width, line2_width). Ties break in favour of the
         split with MORE words on the top line so we never end up with a
         single trailing word on line 2.
      3. Same balanced split, shrunk in 4px steps until both lines fit.

    Returns (lines, font).
    """
    tmp = ImageDraw.Draw(canvas)

    # 1. Try the original at max_size as a single line.
    max_font = load_font(FONT_SCRIPT, max_size)
    bbox = tmp.textbbox((0, 0), event_name, font=max_font)
    if (bbox[2] - bbox[0]) <= max_width:
        return [event_name], max_font

    words = event_name.split()
    if len(words) < 2:
        # Single word doesn't fit — fall back to shrinking it.
        for size in range(max_size, min_size - 1, -4):
            font = load_font(FONT_SCRIPT, size)
            b = tmp.textbbox((0, 0), event_name, font=font)
            if (b[2] - b[0]) <= max_width:
                return [event_name], font
        return [event_name], load_font(FONT_SCRIPT, min_size)

    # 2. Find the best balanced split. Tiebreak rule: when two splits have
    # equal max_w (within 1% of each other), prefer the one with MORE words
    # on line 1 — the top line can be slightly longer, but a one-word orphan
    # on line 2 looks bad.
    best_split = len(words) // 2
    best_max_w = float("inf")
    for split in range(1, len(words)):
        line1 = " ".join(words[:split])
        line2 = " ".join(words[split:])
        b1 = tmp.textbbox((0, 0), line1, font=max_font)
        b2 = tmp.textbbox((0, 0), line2, font=max_font)
        max_w = max(b1[2] - b1[0], b2[2] - b2[0])
        # `<=` (not `<`) means later splits — with more words on the top
        # line — win ties, biasing toward a longer first line.
        if max_w <= best_max_w:
            best_max_w = max_w
            best_split = split

    line1 = " ".join(words[:best_split])
    line2 = " ".join(words[best_split:])

    # 3. Try the wrapped layout at max_size first; only shrink if it doesn't fit.
    for size in range(max_size, min_size - 1, -4):
        font = load_font(FONT_SCRIPT, size)
        b1 = tmp.textbbox((0, 0), line1, font=font)
        b2 = tmp.textbbox((0, 0), line2, font=font)
        if (b1[2] - b1[0]) <= max_width and (b2[2] - b2[0]) <= max_width:
            return [line1, line2], font

    # Last resort — wrapped at min_size even if it overflows slightly.
    return [line1, line2], load_font(FONT_SCRIPT, min_size)


def draw_title(canvas: Image.Image, event_name: str, photo_top_y: int):
    """Draw the event name with inline rose-gold rules — editorial framing device.

    Bottom-anchored to the actual photo top so the gap between title and image
    stays tight regardless of line count or photo aspect ratio. Single-line
    titles and two-line titles both end ~32px above the photo; multi-line
    titles grow upward toward the canvas top."""
    margin = PHOTO_SIDE_MARGIN + 30
    max_text_w = CANVAS_W - 2 * margin - 2 * 28  # room for inline rules + gap
    lines, event_font = _fit_script_title(event_name, canvas, max_text_w)

    tmp_draw = ImageDraw.Draw(canvas)
    line_metrics: list[tuple[int, int]] = []  # (x, width) per line
    text_h_single = 0
    for line in lines:
        bbox = tmp_draw.textbbox((0, 0), line, font=event_font)
        line_w = bbox[2] - bbox[0]
        text_h_single = max(text_h_single, bbox[3] - bbox[1])
        line_metrics.append(((CANVAS_W - line_w) // 2, line_w))
    line_gap = int(text_h_single * 0.85)

    # Anchor the last line ~32px above the photo's actual top. Previous lines
    # stack upward.
    GAP_TO_PHOTO = 32
    last_line_y = photo_top_y - GAP_TO_PHOTO - text_h_single
    first_line_y = last_line_y - (len(lines) - 1) * line_gap

    canvas_rgba = canvas.convert("RGBA")

    # Soft drop shadow — same on every line
    shadow = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    for i, (line, (lx, _)) in enumerate(zip(lines, line_metrics)):
        ly = first_line_y + i * line_gap
        sd.text((lx + 2, ly + 3), line, font=event_font, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=8))
    canvas_rgba = Image.alpha_composite(canvas_rgba, shadow)

    # Inline rose-gold rules — only on the LAST line (most natural editorial framing)
    last_x, last_w = line_metrics[-1]
    line_y = last_line_y + int(text_h_single * 0.52)
    gap = 28

    line_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(line_layer)
    ld.line([(margin, line_y), (last_x - gap, line_y)], fill=(*ROSE_GOLD_DARK, 170), width=1)
    ld.line([(last_x + last_w + gap, line_y), (CANVAS_W - margin, line_y)], fill=(*ROSE_GOLD_DARK, 170), width=1)
    canvas_rgba = Image.alpha_composite(canvas_rgba, line_layer)

    # Crisp text on top
    draw = ImageDraw.Draw(canvas_rgba)
    for i, (line, (lx, _)) in enumerate(zip(lines, line_metrics)):
        ly = first_line_y + i * line_gap
        draw.text((lx, ly), line, font=event_font, fill=TEXT_WHITE)

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
        font = load_font(FONT_DETAIL, 20, index=FONT_DETAIL_INDEX)
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
    canvas, photo_top_y = place_photo(canvas, photo)

    # 3. Draw title with shadow (returns new RGBA canvas)
    canvas = draw_title(canvas, event_name, photo_top_y=photo_top_y)

    # 4. Draw org/venue text (no rule line, gallery style)
    draw = ImageDraw.Draw(canvas)
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
