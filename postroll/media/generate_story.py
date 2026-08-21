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

from .design_tokens import (
    load_font,
    FONT_DETAIL,
    FONT_DETAIL_LIGHT,
    FONT_SCRIPT,
    ROSE_GOLD as ROSE_GOLD_ON_CREAM,
    SAFE_BOTTOM,
    SAFE_TOP,
    TEXT_DARK,
)
from .brand_text import detail_lines


# === Layout, specific to this template ===

CANVAS_W = 1080
CANVAS_H = 1920

# Two rose golds, because this template paints on two backgrounds: the lighter
# one over the blurred photograph, the on-cream accent below it.
ROSE_GOLD_DARK = ROSE_GOLD_ON_CREAM

TEXT_WHITE = (255, 255, 255)  # title (on blurred background)

# Layout — title above photo, generous spacing
PHOTO_TOP_Y = 260  # tighter to title (~50px gap after text)
PHOTO_SIDE_MARGIN = 20
PHOTO_BOTTOM_Y = 1450  # larger photo area (~1190px tall)
ORG_VENUE_Y = 1530  # in the cream caption band below the photo
ORG_VENUE_LINE_SPACING = 55  # slightly tighter line height
#: How far the wordmark's box sits above the bottom edge.
#:
#: Derived from SAFE_BOTTOM rather than set on its own (#753). Instagram lays
#: its account row and caption over the bottom 160px of a story, measured on a
#: published post on 2026-08-20, and at the old 100 the mark's ink ended at
#: y=1780, so the last line of it, PHOTOGRAPHY.COM, was under Instagram's own
#: words on every story.
#:
#: The 20 is the transparent tail the wordmark asset carries at this width,
#: measured rather than assumed: it means the mark's INK lands 20px clear of
#: the band rather than exactly on it. `tests/test_story_title_clamp.py`
#: asserts the ink, not this number, because a check on the number would pass
#: while the visible mark sat in the band.
#:
#: Derived, so a corrected measurement moves the mark with it instead of
#: leaving a constant here that used to be right (L41).
LOGO_BOTTOM_MARGIN = SAFE_BOTTOM - 20

# Background blur
BG_BLUR_RADIUS = 40
BG_DARKEN_OPACITY = 70  # lighter overlay, let warm tones show through

# Light weight (Thin rendered spindly). The second name is what the
# cross-template alignment tests read.
FONT_DETAIL_INDEX = FONT_DETAIL_LIGHT




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


def place_photo(canvas: Image.Image, photo: Image.Image,
                min_top_y: int = PHOTO_TOP_Y) -> tuple[Image.Image, int]:
    """Place the original photo in the upper portion of the canvas.

    Returns (canvas, actual_photo_top_y) so callers can layout against the
    photo's real top edge instead of the wider available band.

    `min_top_y` is a floor the title asks for (#756), not a position. It is
    applied by shrinking the band the photograph is fitted into, so a
    photograph that already sits below it is untouched: a landscape story is
    centred hundreds of pixels lower than any title needs and must render
    exactly as it did before this existed.
    """
    def fitted(top_y: int) -> tuple[int, int, int]:
        """The photograph's size and top edge when the band starts at `top_y`."""
        avail_w = CANVAS_W - (2 * PHOTO_SIDE_MARGIN)
        avail_h = PHOTO_BOTTOM_Y - top_y
        photo_ratio = photo.width / photo.height
        if photo_ratio > avail_w / avail_h:
            # Photo is wider than the available area, so fit to width
            w = avail_w
            h = int(avail_w / photo_ratio)
        else:
            # Photo is taller, so fit to height
            h = avail_h
            w = int(avail_h * photo_ratio)
        return w, h, top_y + (avail_h - h) // 2

    # The natural placement first, and the floor applied only if it misses.
    #
    # Raising the band's top unconditionally would re-centre a photograph that
    # already clears the floor by hundreds of pixels, because the band it is
    # centred in gets shorter as its top rises. A landscape story is exactly
    # that case, and it is every story Dan shoots: the clamp exists for the
    # upright photograph he does not, and it must not move the ones he does.
    new_w, new_h, y = fitted(PHOTO_TOP_Y)
    if y < min_top_y:
        new_w, new_h, y = fitted(min_top_y)

    resized = photo.resize((new_w, new_h), Image.LANCZOS)
    x = (CANVAS_W - new_w) // 2

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


#: How far the title's last line sits above the top edge of the print.
GAP_TO_PHOTO = 32


def title_block(canvas: Image.Image, event_name: str):
    """The laid-out title: its lines, its face, and the two heights.

    One measurement, read by the drawing below and by `required_photo_top`
    above it. Measuring the block twice, once to decide where the photograph
    goes and once to draw, is two definitions of the same quantity and they
    drift in whichever direction flatters the caller (L107).

    Returns (lines, font, line_metrics, text_h_single, line_gap), where
    `line_metrics` is (x, width) per line.
    """
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
    return lines, event_font, line_metrics, text_h_single, line_gap


def required_photo_top(canvas: Image.Image, event_name: str) -> int:
    """The lowest the photograph may start for the title to clear the phone.

    The title is anchored bottom-up off the top edge of the print, so where it
    STARTS is decided by where the photograph ends up, and nothing put a floor
    under it. With an upright photograph the print fills its area and sits at
    `PHOTO_TOP_Y`, which puts a two-line title around y=33, inside the band the
    status bar and Dynamic Island cover (#756).

    So the block is measured first and the photograph is started below it. This
    is a floor, not a position: `place_photo` takes the LOWER of this and the
    photograph's natural placement, so a landscape story, which already clears
    the band by hundreds of pixels, is not moved at all.

    The title fitter never returns more than two lines and shrinks the face
    until they fit, so the deepest block this can ask for is about 360, leaving
    the print over a thousand pixels of height. There is no case where this
    squeezes the photograph to nothing.
    """
    if not event_name:
        return PHOTO_TOP_Y
    lines, _, _, text_h_single, line_gap = title_block(canvas, event_name)
    block_h = text_h_single + (len(lines) - 1) * line_gap
    # Where the INK starts relative to the y the glyphs are drawn at, which is
    # not the same number: Pillow anchors at the ascender and the script face
    # can carry a swash above it. Clamping the anchor to SAFE_TOP would leave
    # whatever rises above it inside the covered band, one pixel of it being
    # exactly as unreadable as fifty (L67).
    ink_offset = _title_ink_offset(canvas, event_name)
    return SAFE_TOP - ink_offset + block_h + GAP_TO_PHOTO


def _title_ink_offset(canvas: Image.Image, event_name: str) -> int:
    """How far the title's topmost ink sits below the y it is drawn at.

    Negative when a glyph reaches ABOVE the anchor, which is the case that
    matters: it is what has to be added back to the clearance.
    """
    lines, font, _, _, _ = title_block(canvas, event_name)
    draw = ImageDraw.Draw(canvas)
    return min(draw.textbbox((0, 0), line, font=font)[1] for line in lines)


def draw_title(canvas: Image.Image, event_name: str, photo_top_y: int):
    """Draw the event name with inline rose-gold rules, an editorial framing device.

    Bottom-anchored to the actual photo top so the gap between title and image
    stays tight regardless of line count or photo aspect ratio. Single-line
    titles and two-line titles both end ~32px above the photo; multi-line
    titles grow upward toward the canvas top.

    The floor under it is `required_photo_top`, applied when the photograph is
    placed rather than here: clamping the TITLE would detach it from the top
    edge of the print, which is the whole shape of this template.
    """
    lines, event_font, line_metrics, text_h_single, line_gap = title_block(
        canvas, event_name)

    # Anchor the last line ~32px above the photo's actual top. Previous lines
    # stack upward.
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
    margin = PHOTO_SIDE_MARGIN + 30
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


def draw_text(draw: ImageDraw.ImageDraw, org: str, venue: str, event_name: str = ""):
    """Draw org/venue text.

    event_name is needed to drop an org that only repeats the title drawn above
    it (`brand_text.detail_lines`). It defaults to empty so an existing caller
    passing two arguments still renders both lines rather than failing.
    """

    # Org and Venue — Helvetica Neue Thin, wide spacing, on separate lines
    venue_font = load_font(FONT_DETAIL, 38, index=FONT_DETAIL_INDEX)
    line_spacing = ORG_VENUE_LINE_SPACING
    spacing = 8  # extra pixels between characters for tracking

    for i, line_text in enumerate(detail_lines(event_name, org, venue)):
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

    # 2. Place original photo, below whatever room the title needs (#756)
    canvas, photo_top_y = place_photo(
        canvas, photo, min_top_y=required_photo_top(canvas, event_name))

    # 3. Draw title with shadow (returns new RGBA canvas)
    canvas = draw_title(canvas, event_name, photo_top_y=photo_top_y)

    # 4. Draw org/venue text (no rule line, gallery style)
    draw = ImageDraw.Draw(canvas)
    draw_text(draw, org, venue, event_name)

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
