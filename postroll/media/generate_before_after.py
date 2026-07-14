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

# Reuse the title-fitting helper from the story template so single-line
# shrink + two-line wrap behavior stays consistent across both layouts.
from .generate_story import _fit_script_title


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
LABEL_MARGIN = 40   # snug to the photo's top-left corner; reel closing-frame zoom may crop slightly but the label isn't load-bearing
LABEL_STRIP_H = 58  # cream strip ABOVE each photo carrying its RAW/Edit/B&W label
EDITED_PHOTO_SCALE = 1.12  # in 3-photo mode, edits render slightly larger than the RAW
LOGO_WIDTH = 280
BOTTOM_CREAM_H = 130  # taller bottom to balance the top
HEADER_MIN_H = 400  # min header height to accommodate notch-safe title + org + venue
TITLE_TOP_PADDING = 170  # clears iPhone notch/Dynamic Island (~120px) with breathing room

# Fonts (same as story template)
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"
# Light, not Thin: the detail line rendered spindly in Thin (the .ttc Thin face).
FONT_DETAIL_LIGHT = 7
FONT_DETAIL_BOLD = 1  # RAW/Edit labels need to read at Instagram phone size; Thin disappears


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
    detail_font = load_font(FONT_DETAIL, 30, index=FONT_DETAIL_LIGHT)
    org_venue_y = start_y + text_h + 45

    for i, line in enumerate([org, venue]):
        y = org_venue_y + i * 42
        draw_spaced_text_centered(draw, line, detail_font, TEXT_DARK, CANVAS_W // 2, y)

    # No rule line at the header bottom (gallery style).

    return canvas


def generate_before_after(
    raw_path: str,
    edit_path: str,
    output_path: str,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    logo_path: str | None = None,
    raw_label_color: str = "auto",  # "auto" (pick from the pixels beneath), "light" or "dark"
    raw_label_pos: str = "left",  # "left" or "right"
    edit_label_color: str = "auto",
    edit_label_pos: str = "left",
    bw_path: str | None = None,
) -> str:
    """Generate a before/after comparison image.

    Two-photo layout (default, top to bottom):
        - Cream header (event name, org, venue — matching story template)
        - "RAW" label strip
        - RAW photo (fit to width, uncropped)
        - "Edit" label strip
        - Edited photo (fit to width, uncropped)
        - Bottom area with logo

    When ``bw_path`` is provided, a third strip (the B&W after) is stacked
    below the color edit, so the layout reads RAW / Edit / B&W. Each photo
    fits to width at its own height, so the B&W can be a different crop.
    """
    raw_photo = Image.open(raw_path)
    edit_photo = Image.open(edit_path)
    bw_photo = Image.open(bw_path) if bw_path else None
    label_font = load_font(FONT_DETAIL, LABEL_FONT_SIZE, index=FONT_DETAIL_BOLD)
    detail_font = load_font(FONT_DETAIL, 30, index=FONT_DETAIL_LIGHT)

    # Flat cream background (gallery style): the cream bands compose cream over
    # cream, so the header/footer read true cream instead of grey over a blurred,
    # darkened copy of the photo.
    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (*CREAM, 255))

    # Auto-fit the script title — wraps to two lines (or shrinks) if the title
    # doesn't fit on one at max size.
    title_max_w = CANVAS_W - 2 * 80  # 80px each side keeps title clear of zoom-crop area
    title_lines, title_font = _fit_script_title(event_name, canvas, title_max_w)

    # Compute the actual header height needed for THIS title + org/venue,
    # before reserving photo space. Two-line titles at full size need more
    # room than the static HEADER_MIN_H ever budgeted for.
    draw_tmp = ImageDraw.Draw(canvas)
    title_h_single = 0
    for line in title_lines:
        bbox = draw_tmp.textbbox((0, 0), line, font=title_font)
        title_h_single = max(title_h_single, bbox[3] - bbox[1])
    title_line_gap = int(title_h_single * 0.85)
    title_block_bottom = (
        TITLE_TOP_PADDING + (len(title_lines) - 1) * title_line_gap + title_h_single
    )
    org_venue_count = sum(1 for s in (org, venue) if s)
    info_y = TITLE_TOP_PADDING + (len(title_lines) - 1) * title_line_gap + 110
    info_block_bottom = info_y + max(0, org_venue_count - 1) * 42 + 36
    header_min_needed = max(HEADER_MIN_H, info_block_bottom + 30)  # 30px breathing room

    # Photos to stack: RAW + color edit, plus the B&W after when supplied.
    source_photos = [raw_photo, edit_photo]
    if bw_photo is not None:
        source_photos.append(bw_photo)
    photo_count = len(source_photos)

    # Reserve header + footer + chrome first; photos share what's left, so the
    # notch-safe title area is never squeezed by tall photos. Each photo gets a
    # cream label strip ABOVE it (RAW / Edit / B&W), so the label is always dark
    # ink on cream and legible over any photo, never overlaid on a busy frame.
    fixed_chrome = DIVIDER_H * 2 + LABEL_STRIP_H * photo_count
    photos_budget = CANVAS_H - header_min_needed - BOTTOM_CREAM_H - fixed_chrome

    # Height budget per photo. In 3-photo mode the edits (color + B&W) get a
    # slightly larger share than the RAW so the "after" reads as the hero; the
    # classic two-photo before/after keeps equal sizing.
    if bw_photo is not None:
        weights = [1.0, EDITED_PHOTO_SCALE, EDITED_PHOTO_SCALE]
    else:
        weights = [1.0] * photo_count
    total_weight = sum(weights)
    photo_caps = [int(photos_budget * (w / total_weight)) for w in weights]

    resized_photos = [
        fit_photo(p, CANVAS_W, cap) for p, cap in zip(source_photos, photo_caps)
    ]
    total_photo_h = sum(p.height for p in resized_photos)

    # Any leftover space (when photos are shorter than their cap) is split
    # between header and footer so the layout stays centered.
    remaining = CANVAS_H - total_photo_h - fixed_chrome
    extra = remaining - header_min_needed - BOTTOM_CREAM_H
    header_cream_h = header_min_needed + max(0, extra) // 2
    footer_cream_h = remaining - header_cream_h

    y = 0

    # === CREAM HEADER: title, org, venue (starts at top edge) ===
    canvas = apply_cream_strip(canvas, 0, header_cream_h)
    draw = ImageDraw.Draw(canvas)

    # Title — auto-shrunk and possibly two-line. Each line drawn centered.
    # title_h_single, title_line_gap, info_y already computed above when we
    # sized the header.
    title_y = TITLE_TOP_PADDING
    for i, line in enumerate(title_lines):
        bbox = draw.textbbox((0, 0), line, font=title_font)
        tw = bbox[2] - bbox[0]
        tx = (CANVAS_W - tw) // 2
        draw.text((tx, title_y + i * title_line_gap), line, font=title_font, fill=TEXT_DARK)

    # Org/venue follow the title (single or wrapped). Fixed offset from the
    # last title line so the spacing stays consistent regardless of wrap.
    for j, line in enumerate([org, venue]):
        if line:
            draw_spaced_text_centered(draw, line, detail_font, TEXT_DARK, CANVAS_W // 2, info_y + j * 42)

    y = header_cream_h

    # Header → photos boundary: no rule line (gallery style). The DIVIDER_H of
    # space is kept as an invisible cream gap so the layout math stays put.
    y += DIVIDER_H

    # === PHOTOS, each under a cream label strip ===
    labels = ["RAW", "Edit"] + (["B&W"] if bw_photo is not None else [])

    for photo_resized, label_text in zip(resized_photos, labels):
        # Cream strip ABOVE the photo, carrying the label in dark ink. Left-aligned,
        # letter-spaced, vertically centred in the strip.
        canvas = apply_cream_strip(canvas, y, LABEL_STRIP_H)
        draw = ImageDraw.Draw(canvas)
        lb = label_font.getbbox(label_text)
        ly = y + (LABEL_STRIP_H - (lb[3] - lb[1])) // 2 - lb[1]
        tx = LABEL_MARGIN
        for ch in label_text:
            draw.text((tx, ly), ch, font=label_font, fill=TEXT_DARK)
            cb = draw.textbbox((0, 0), ch, font=label_font)
            tx += (cb[2] - cb[0]) + LABEL_LETTER_SPACING
        y += LABEL_STRIP_H

        px = (CANVAS_W - photo_resized.width) // 2
        canvas.paste(photo_resized.convert("RGBA"), (px, y), photo_resized.convert("RGBA"))
        y += photo_resized.height

    # Photos → footer boundary: no rule line (gallery style); keep the gap.
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
    parser.add_argument("--bw", default=None, help="Optional path to B&W edit (adds a 3rd stacked strip)")
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
        bw_path=args.bw,
    )


if __name__ == "__main__":
    main()
