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
from PIL import Image, ImageDraw, ImageFont

# Reuse the title-fitting helper from the story template so single-line
# shrink + two-line wrap behavior stays consistent across both layouts.
from .generate_story import _fit_script_title
from .missing_media import require_present
from .brand_text import detail_lines

from .design_tokens import (
    CREAM,
    CREAM_EDGE,
    FONT_DETAIL,
    FONT_DETAIL_LIGHT,
    FONT_DETAIL_MEDIUM,
    MAT_PRINT as MAT,
    ROSE_GOLD,
    TEXT_DARK,
    WARM_MID,
)

# MAT is the even side mat; the photos are hung as matted prints inside it, and
# CREAM_EDGE is the print's hairline.


# === Layout, specific to this template ===

CANVAS_W = 1080
CANVAS_H = 1920

CREAM_OPACITY = 185  # lower opacity lets blurred photo warmth show through

# Layout: left-aligned program plate (matches the Tuesday reel body)
DIVIDER_H = 2
LABEL_LETTER_SPACING = 8
LABEL_MARGIN = 40
# Caption placard ABOVE each photo, centred like a museum wall card: a state word
# over a quiet subtitle. Centred to share the title's axis so it reads composed,
# not stuck in a corner.
LABEL_STRIP_H = 92
PLACARD_FONT_SIZE = 24
PLACARD_LETTER_SPACING = 9
SUBTITLE_FONT_SIZE = 15
SUBTITLE_LETTER_SPACING = 4
EDITED_PHOTO_SCALE = 1.12  # in 3-photo mode, edits render slightly larger than the RAW
LOGO_WIDTH = 460  # readable at phone size, including the small PHOTOGRAPHY.COM line
# The closing colophon: a rose-gold rule, a gap, then the mark centred beneath.
# The footer has to reserve all three or the mark runs off the bottom of the
# page, which is what BOTTOM_CREAM_H alone did: 130px of footer for a block
# needing 170, so the PHOTOGRAPHY.COM line and half the wordmark were cut off
# the canvas (found by the reference frame in #163).
LOGO_TOP_GAP = 32
LOGO_BOTTOM_MARGIN = 24
BOTTOM_CREAM_H = 130  # taller bottom to balance the top
HEADER_MIN_H = 400  # min header height to accommodate notch-safe title + org + venue
TITLE_TOP_PADDING = 170  # clears iPhone notch/Dynamic Island (~120px) with breathing room

# The placard subtitle in Light read too thin at phone size; Medium holds up.
SUBTITLE_WEIGHT = FONT_DETAIL_MEDIUM


# The gallery-card wording for each photo. A state word over a quiet subtitle.
PLACARD_TEXT = {
    "RAW": ("BEFORE", "UNEDITED CAPTURE"),
    "Edit": ("AFTER", "FINAL EDIT"),
    "B&W": ("B&W", "BLACK & WHITE"),
}


def placard_text(state: str) -> tuple[str, str]:
    """(word, subtitle) for a photo's gallery caption card."""
    return PLACARD_TEXT.get(state, (state.upper(), ""))


def _tracked(draw, text, font, fill, x, y, spacing):
    """Draw left-aligned, letter-spaced text (the program-plate look)."""
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        b = draw.textbbox((0, 0), ch, font=font)
        x += (b[2] - b[0]) + spacing


def header_detail_lines(event_name: str, org: str, venue: str) -> list[str]:
    """The letterspaced lines under the script title.

    Kept as this template's own name for the shared rule in `brand_text`, since
    the layout code below reads better talking about header lines.
    """
    return detail_lines(event_name, org, venue)


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
    # Every chosen input is checked by name before anything is opened, so a
    # missing file reports which slot it was rather than a bare
    # FileNotFoundError naming a path (#180).
    raw_path = require_present(raw_path, "RAW photo")
    edit_path = require_present(edit_path, "edited photo")
    bw_path = require_present(bw_path, "B&W photo")

    raw_photo = Image.open(raw_path)
    edit_photo = Image.open(edit_path)
    bw_photo = Image.open(bw_path) if bw_path else None
    placard_font = load_font(FONT_DETAIL, PLACARD_FONT_SIZE, index=FONT_DETAIL_MEDIUM)
    subtitle_font = load_font(FONT_DETAIL, SUBTITLE_FONT_SIZE, index=SUBTITLE_WEIGHT)
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
    detail_lines = header_detail_lines(event_name, org, venue)
    info_y = TITLE_TOP_PADDING + (len(title_lines) - 1) * title_line_gap + 110
    info_block_bottom = info_y + max(0, len(detail_lines) - 1) * 42 + 36
    header_min_needed = max(HEADER_MIN_H, info_block_bottom + 30)  # 30px breathing room

    # The logo is loaded HERE, before the space budget, because the footer has
    # to be tall enough to hold it. Sizing the footer from a constant and then
    # discovering the mark is taller is how it came to be cut off the page.
    # Refuses a mark that was asked for and is not on disk, rather than sizing
    # the footer for no signature and reporting success (#334).
    from .wordmark import load as _load_wordmark
    logo = _load_wordmark(logo_path, LOGO_WIDTH)
    footer_min_needed = max(
        BOTTOM_CREAM_H,
        20 + LOGO_TOP_GAP + (logo.height if logo else 0) + LOGO_BOTTOM_MARGIN)

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
    photos_budget = CANVAS_H - header_min_needed - footer_min_needed - fixed_chrome

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
        fit_photo(p, CANVAS_W - 2 * MAT, cap) for p, cap in zip(source_photos, photo_caps)
    ]
    total_photo_h = sum(p.height for p in resized_photos)

    # Any leftover space (when photos are shorter than their cap) is split
    # between header and footer so the layout stays centered.
    remaining = CANVAS_H - total_photo_h - fixed_chrome
    extra = remaining - header_min_needed - footer_min_needed
    header_cream_h = header_min_needed + max(0, extra) // 2
    footer_cream_h = remaining - header_cream_h

    y = 0

    # === CREAM HEADER: title, org, venue (starts at top edge) ===
    canvas = apply_cream_strip(canvas, 0, header_cream_h)
    draw = ImageDraw.Draw(canvas)

    # Masthead, top-LEFT (matches the Tuesday reel body), on a rose-gold rule.
    title_y = TITLE_TOP_PADDING
    for i, line in enumerate(title_lines):
        draw.text((MAT, title_y + i * title_line_gap), line, font=title_font, fill=TEXT_DARK)

    # Org/venue follow the title, left-aligned. The org is dropped when it equals
    # the event name (header_detail_lines).
    detail_bottom = info_y
    for j, line in enumerate(detail_lines):
        _tracked(draw, line.upper(), detail_font, WARM_MID, MAT, info_y + j * 42, 5)
        detail_bottom = info_y + j * 42 + 30
    rule_y = detail_bottom + 20
    draw.line([(MAT, rule_y), (CANVAS_W - MAT, rule_y)], fill=ROSE_GOLD, width=1)

    y = header_cream_h + DIVIDER_H

    # === PHOTOS, each a matted print under a LEFT-aligned caption placard ===
    states = ["RAW", "Edit"] + (["B&W"] if bw_photo is not None else [])

    for photo_resized, state in zip(resized_photos, states):
        canvas = apply_cream_strip(canvas, y, LABEL_STRIP_H)
        draw = ImageDraw.Draw(canvas)
        word, subtitle = placard_text(state)
        _tracked(draw, word, placard_font, ROSE_GOLD, MAT, y + 18, PLACARD_LETTER_SPACING)
        if subtitle:
            _tracked(draw, subtitle, subtitle_font, WARM_MID, MAT, y + 56, SUBTITLE_LETTER_SPACING)
        y += LABEL_STRIP_H

        px = MAT
        canvas.paste(photo_resized.convert("RGBA"), (px, y), photo_resized.convert("RGBA"))
        ImageDraw.Draw(canvas).rectangle(
            [px - 1, y - 1, px + photo_resized.width, y + photo_resized.height],
            outline=CREAM_EDGE, width=1)
        y += photo_resized.height

    y += DIVIDER_H

    # === FOOTER COLOPHON: a rose-gold rule and the centred DW mark ===
    # The rule closes the page whether or not a logo is supplied.
    canvas = apply_cream_strip(canvas, y, footer_cream_h)
    draw = ImageDraw.Draw(canvas)

    # The logo was loaded with the space budget above, so the footer is already
    # tall enough for the whole block: rule, gap, mark, bottom margin.
    logo_h = logo.height if logo else 0
    block_h = LOGO_TOP_GAP + logo_h + LOGO_BOTTOM_MARGIN if logo else 0
    rule_y = y + max(20, (footer_cream_h - block_h) // 2)
    if logo:
        # Last line of defence. Whatever the budget above worked out, the mark
        # does not leave the page: a clipped wordmark is worse than a footer
        # that sits a little high, and it shipped once because nothing checked.
        rule_y = min(rule_y, CANVAS_H - LOGO_BOTTOM_MARGIN - logo_h - LOGO_TOP_GAP)
        rule_y = max(rule_y, y)
    draw.line([(MAT, rule_y), (CANVAS_W - MAT, rule_y)], fill=ROSE_GOLD, width=1)
    if logo:
        canvas.paste(logo, ((CANVAS_W - logo.width) // 2, rule_y + LOGO_TOP_GAP), logo)

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
