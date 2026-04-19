"""
PostRoll — Photo Scroll Reel Generator

Creates a 1080x1920 vertical reel that smoothly scrolls through a masonry
collage strip of photos. Used for: Thursday photo scroll reel.

Photos are arranged in collage rows (1, 2, or 3 per row) and the camera
pans from top to bottom with easing.

Usage:
    python generate_reel_scroll.py \
        --photos photo1.jpg photo2.jpg ... \
        --audio music.m4a --output output/reel.mp4
"""

from __future__ import annotations

import argparse
import json
import random
import subprocess
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# Reuse the collage's pan/zoom-aware crop so per-photo offsets produce
# identical output in both the strip preview PNG and the final encoded reel.
from .generate_collage import crop_to_fill as _crop_to_fill


# === Design Tokens ===

CANVAS_W = 1080
CANVAS_H = 1920
FPS = 30

# Collage layout
ROW_GAP = 8            # gap between rows (cream colored)
COL_GAP = 8            # gap between photos in a row
SIDE_MARGIN = 30       # left/right margins
CREAM_BG = (240, 235, 228)  # warm cream for gaps

# Row patterns — fewer heroes, more pairs/trios for even density
ROW_SIZES = [2, 3, 2, 3, 2, 3, 3, 1, 2, 3, 2, 3]  # hero every ~8th row

# Max height cap for hero (single photo) rows — prevents them dominating
HERO_MAX_H = 480

# Scroll timing
SCROLL_DURATION = 30.0   # seconds to scroll the full strip
HOLD_END = 1.0           # hold at bottom before closing
CLOSING_FRAME_DURATION = 5.0

# Branded chrome
CREAM = (252, 250, 247)
CREAM_OPACITY = 210
TEXT_DARK = (60, 55, 50)
ROSE_GOLD = (160, 105, 95)
HEADER_H = 220
FOOTER_H = 100
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"
FONT_DETAIL_THIN = 12
LOGO_WIDTH = 200

# Audio
AUDIO_FADE_DURATION = 5.0


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        return ImageFont.load_default()


def ease_in_out(t: float) -> float:
    """More dramatic ease — slower start and end, noticeable acceleration."""
    if t < 0.12:
        return (t / 0.12) ** 2.5 * 0.06
    elif t > 0.88:
        p = (t - 0.88) / 0.12
        return 0.94 + (1 - (1 - p) ** 2.5) * 0.06
    else:
        return 0.06 + (t - 0.12) / 0.76 * 0.88


def build_collage_strip(
    photo_paths: list[str],
    seed: int | None = None,
    crop_offsets: list[tuple[float, float, float]] | None = None,
    return_layout: bool = False,
):
    """Build a tall collage strip from photos arranged in masonry rows.

    crop_offsets: optional list of (x, y, zoom) triples in [-1, 1] / [≥1]
                  parallel to photo_paths. Default (0, 0, 1) = centred fill
                  with the original 0.4 top-bias used in generate_collage.
    return_layout: when True, returns (strip_image, cells) where cells is a
                   list of {photo_path, x, y, w, h} dicts in strip-pixel
                   coordinates — used by the app to overlay crop controls.
    """
    rng = random.Random(seed)
    photos = [Image.open(p) for p in photo_paths]
    n = len(photos)

    # Generate row pattern
    pattern = []
    remaining = n
    idx = 0
    while remaining > 0:
        size = ROW_SIZES[idx % len(ROW_SIZES)]
        size = min(size, remaining)
        pattern.append(size)
        remaining -= size
        idx += 1

    avail_w = CANVAS_W - 2 * SIDE_MARGIN

    # Calculate natural row heights based on photo aspect ratios
    row_data = []  # (photos_in_row, height, widths)
    photo_idx = 0
    for photos_in_row in pattern:
        col_gaps = (photos_in_row - 1) * COL_GAP
        row_avail_w = avail_w - col_gaps

        # Get aspect ratios
        ratios = [photos[photo_idx + j].width / photos[photo_idx + j].height
                  for j in range(photos_in_row)]

        # Natural height where all photos fit side by side
        natural_h = int(row_avail_w / sum(ratios))

        # Cap hero rows so they don't dominate scroll time
        if photos_in_row == 1 and natural_h > HERO_MAX_H:
            natural_h = HERO_MAX_H

        # Compute widths with slight asymmetry
        if photos_in_row == 1:
            widths = [row_avail_w]
        elif photos_in_row == 2:
            split = rng.choice([0.55, 0.45, 0.52, 0.48, 0.57, 0.43])
            w1 = int(row_avail_w * split)
            widths = [w1, row_avail_w - w1]
        elif photos_in_row == 3:
            # More even splits — no cell narrower than ~310px
            splits = rng.choice([
                (0.36, 0.32, 0.32),
                (0.32, 0.36, 0.32),
                (0.32, 0.32, 0.36),
                (0.34, 0.34, 0.32),
            ])
            w1 = int(row_avail_w * splits[0])
            w2 = int(row_avail_w * splits[1])
            widths = [w1, w2, row_avail_w - w1 - w2]
        else:
            base = row_avail_w // photos_in_row
            widths = [base] * photos_in_row
            widths[-1] = row_avail_w - base * (photos_in_row - 1)

        row_data.append((photos_in_row, natural_h, widths))
        photo_idx += photos_in_row

    # Add padding at top and bottom so photos aren't hidden behind chrome
    top_pad = HEADER_H + ROW_GAP * 3  # extra breathing room below header
    bottom_pad = FOOTER_H + 30  # just enough to clear footer with a small gap
    total_h = top_pad + sum(h for _, h, _ in row_data) + ROW_GAP * (len(row_data) - 1) + bottom_pad

    # Create strip with cream background
    strip = Image.new("RGB", (CANVAS_W, total_h), CREAM_BG)

    cells: list[dict] = []

    # Place photos below header zone
    y = top_pad
    photo_idx = 0
    for photos_in_row, row_h, widths in row_data:
        x = SIDE_MARGIN
        for col_idx in range(photos_in_row):
            if crop_offsets and photo_idx < len(crop_offsets):
                ox, oy, oz = crop_offsets[photo_idx]
            else:
                ox, oy, oz = 0.0, 0.0, 1.0
            cropped = _crop_to_fill(
                photos[photo_idx], widths[col_idx], row_h, ox, oy, oz,
            )
            strip.paste(cropped, (x, y))
            cells.append({
                "photo_path": str(photo_paths[photo_idx]),
                "x": x,
                "y": y,
                "w": widths[col_idx],
                "h": row_h,
            })
            x += widths[col_idx] + COL_GAP
            photo_idx += 1
        y += row_h + ROW_GAP

    if return_layout:
        return strip, cells
    return strip


def draw_branded_chrome(frame: Image.Image, event_name: str, org: str,
                        venue: str, logo: Image.Image | None) -> Image.Image:
    """Draw cream header and footer."""
    frame_rgba = frame.convert("RGBA")

    header = Image.new("RGBA", (CANVAS_W, HEADER_H), (*CREAM, 255))
    frame_rgba.paste(header, (0, 0), header)
    draw = ImageDraw.Draw(frame_rgba)
    draw.line([(0, HEADER_H - 1), (CANVAS_W, HEADER_H - 1)], fill=ROSE_GOLD, width=2)

    title_font = load_font(FONT_SCRIPT, 70)
    detail_font = load_font(FONT_DETAIL, 26, index=FONT_DETAIL_THIN)
    bbox = draw.textbbox((0, 0), event_name, font=title_font)
    tw = bbox[2] - bbox[0]
    draw.text(((CANVAS_W - tw) // 2, 35), event_name, font=title_font, fill=TEXT_DARK)

    title_h = bbox[3] - bbox[1]
    info_y = 35 + title_h + 20
    for j, line in enumerate([org, venue]):
        if line:
            total_w = sum(draw.textbbox((0, 0), ch, font=detail_font)[2] -
                         draw.textbbox((0, 0), ch, font=detail_font)[0] + 6
                         for ch in line) - 6
            x = (CANVAS_W - total_w) // 2
            for ch in line:
                draw.text((x, info_y + j * 36), ch, font=detail_font, fill=TEXT_DARK)
                cb = draw.textbbox((0, 0), ch, font=detail_font)
                x += (cb[2] - cb[0]) + 6

    footer_y = CANVAS_H - FOOTER_H
    footer = Image.new("RGBA", (CANVAS_W, FOOTER_H), (*CREAM, 255))
    frame_rgba.paste(footer, (0, footer_y), footer)
    draw = ImageDraw.Draw(frame_rgba)
    draw.line([(0, footer_y), (CANVAS_W, footer_y)], fill=ROSE_GOLD, width=2)

    if logo:
        lx = (CANVAS_W - logo.width) // 2
        ly = footer_y + (FOOTER_H - logo.height) // 2
        frame_rgba.paste(logo, (lx, ly), logo)

    return frame_rgba.convert("RGB")


_DEFAULT_AUDIO_TAGS = "ambient,atmospheric"


def build_reel_preview(
    photo_paths: list[str],
    output_path: str,
    seed: int | None = None,
    crop_offsets: list[tuple[float, float, float]] | None = None,
) -> str:
    """Render the reel's photo strip as a standalone PNG + layout sidecar.

    Fast path used by the app's Thursday editor: skips ffmpeg encoding and
    just writes the masonry strip (applying any crop offsets) plus a JSON
    sidecar describing each photo cell's rect in strip-pixel coordinates.

    Returns the absolute PNG path. The sidecar is written alongside as
    {output_stem}_layout.json with shape:
        {"strip_width": W, "strip_height": H, "cells": [{photo_path, x, y, w, h}, ...]}
    """
    print(f"Building reel preview strip from {len(photo_paths)} photos...")
    strip, cells = build_collage_strip(
        photo_paths, seed=seed, crop_offsets=crop_offsets, return_layout=True,
    )

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    strip.save(str(output), "PNG", quality=95)

    layout_path = output.parent / (output.stem + "_layout.json")
    with open(layout_path, "w") as lf:
        json.dump({
            "strip_width":  strip.width,
            "strip_height": strip.height,
            "cells":        cells,
        }, lf)

    print(f"Reel preview written: {output} ({strip.width}x{strip.height}, {len(cells)} cells)")
    return str(output)


def generate_reel_scroll(
    photo_paths: list[str],
    audio_path: str | None,   # None = auto-fetch from Jamendo
    output_path: str,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    closing_frame_path: str | None = None,
    logo_path: str | None = None,
    gap: int = ROW_GAP,
    seed: int | None = None,
    scroll_duration: float = SCROLL_DURATION,
    audio_tags: str | None = None,  # override default Jamendo search tags
    crop_offsets: list[tuple[float, float, float]] | None = None,
) -> str:
    """Generate a photo scroll reel with masonry collage layout.

    scroll_duration: seconds to scroll the full strip (default 30.0).
    audio_tags: comma-separated Jamendo tags; overrides _DEFAULT_AUDIO_TAGS when provided.
    crop_offsets: optional per-photo (x, y, zoom) triples — lets the Thursday
                  editor override the default centred fill on a per-photo basis.
    """
    if audio_path is None:
        from postroll.audio import fetch_audio
        audio_path = fetch_audio(audio_tags or _DEFAULT_AUDIO_TAGS)

    # Sort photos by filename using natural (numeric) order so that
    # "-3" comes before "-13" comes before "-101".
    import re as _re
    from pathlib import Path as _Path

    def _natural_key(name: str) -> list:
        """Split filename into text/number chunks for natural sorting."""
        return [int(c) if c.isdigit() else c.lower() for c in _re.split(r'(\d+)', name)]

    print(f"[generate_reel_scroll] BEFORE sort ({len(photo_paths)} photos):", flush=True)
    for i, p in enumerate(photo_paths):
        print(f"  [{i}] {_Path(p).name}", flush=True)
    if crop_offsets:
        paired = sorted(zip(photo_paths, crop_offsets), key=lambda p: _natural_key(_Path(p[0]).name))
        photo_paths = [p for p, _ in paired]
        crop_offsets = [o for _, o in paired]
    else:
        photo_paths = sorted(photo_paths, key=lambda p: _natural_key(_Path(p).name))
    print(f"[generate_reel_scroll] AFTER sort ({len(photo_paths)} photos):", flush=True)
    for i, p in enumerate(photo_paths):
        print(f"  [{i}] {_Path(p).name}", flush=True)

    n = len(photo_paths)
    total_duration = scroll_duration + HOLD_END + CLOSING_FRAME_DURATION

    # Build collage strip
    print(f"Building collage strip from {n} photos...")
    strip = build_collage_strip(photo_paths, seed=seed, crop_offsets=crop_offsets)
    strip_h = strip.height
    print(f"Strip size: {CANVAS_W}x{strip_h}")

    # Scroll exactly to bottom of strip — bottom_pad handles footer clearance
    max_scroll = max(1, strip_h - CANVAS_H)

    # Load logo
    logo = None
    if logo_path and Path(logo_path).exists():
        logo = Image.open(logo_path).convert("RGBA")
        logo_scale = LOGO_WIDTH / logo.width
        logo = logo.resize(
            (int(logo.width * logo_scale), int(logo.height * logo_scale)),
            Image.LANCZOS,
        )

    # Load closing frame
    closing_frame = None
    if closing_frame_path and Path(closing_frame_path).exists():
        closing_frame = Image.open(closing_frame_path).convert("RGB")
        closing_frame = closing_frame.resize((CANVAS_W, CANVAS_H), Image.LANCZOS)

    total_frames = int(total_duration * FPS)
    scroll_frames = int(scroll_duration * FPS)
    hold_frames = int(HOLD_END * FPS)

    print(f"Generating {total_frames} frames ({scroll_duration}s scroll)...")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        for i in range(total_frames):
            if i < scroll_frames:
                t = i / scroll_frames
                eased = ease_in_out(t)
                scroll_y = int(eased * max_scroll)
                frame = strip.crop((0, scroll_y, CANVAS_W, scroll_y + CANVAS_H))
                frame = draw_branded_chrome(frame, event_name, org, venue, logo)

            elif i < scroll_frames + hold_frames:
                frame = strip.crop((0, max_scroll, CANVAS_W, max_scroll + CANVAS_H))
                frame = draw_branded_chrome(frame, event_name, org, venue, logo)

            else:
                if closing_frame:
                    closing_i = i - scroll_frames - hold_frames
                    if closing_i < FPS:
                        blend = closing_i / FPS
                        last = strip.crop((0, max_scroll, CANVAS_W, max_scroll + CANVAS_H))
                        last = draw_branded_chrome(last, event_name, org, venue, logo)
                        frame = Image.blend(last, closing_frame, blend)
                    else:
                        frame = closing_frame
                else:
                    frame = strip.crop((0, max_scroll, CANVAS_W, max_scroll + CANVAS_H))
                    frame = draw_branded_chrome(frame, event_name, org, venue, logo)

            frame.save(str(tmpdir / f"frame_{i:05d}.png"), "PNG")

        # Encode
        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)

        cmd = [
            "ffmpeg", "-y",
            "-framerate", str(FPS),
            "-i", str(tmpdir / "frame_%05d.png"),
            "-i", audio_path,
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-af", (
                f"atrim=0:{total_duration},"
                f"afade=t=out:st={total_duration - AUDIO_FADE_DURATION}:d={AUDIO_FADE_DURATION},"
                f"apad"
            ),
            "-t", str(total_duration),
            str(output),
        ]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {result.stderr[-500:]}")

    print(f"Scroll reel generated: {output} ({total_duration:.1f}s, {n} photos)")
    return str(output)


def main():
    parser = argparse.ArgumentParser(description="Generate a photo scroll reel")
    parser.add_argument("--photos", nargs="+", required=True)
    parser.add_argument("--audio", default=None, help="Path to audio file (omit to auto-fetch from Jamendo)")
    parser.add_argument("--event", default="")
    parser.add_argument("--org", default="")
    parser.add_argument("--venue", default="")
    parser.add_argument("--closing-frame", default=None)
    parser.add_argument("--logo", default=None)
    parser.add_argument("--gap", type=int, default=ROW_GAP)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--output", default="output/reel_scroll.mp4")
    args = parser.parse_args()

    generate_reel_scroll(
        photo_paths=args.photos,
        audio_path=args.audio,
        output_path=args.output,
        event_name=args.event,
        org=args.org,
        venue=args.venue,
        closing_frame_path=args.closing_frame,
        logo_path=args.logo,
        gap=args.gap,
        seed=args.seed,
    )


if __name__ == "__main__":
    main()
