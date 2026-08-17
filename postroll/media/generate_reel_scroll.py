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
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

# Reuse the collage's pan/zoom-aware crop so per-photo offsets produce
# identical output in both the strip preview PNG and the final encoded reel.
from .generate_collage import DEFAULT_CROP_OFFSET, crop_to_fill as _crop_to_fill

from .design_tokens import (
    load_font,
    CREAM,
    FONT_DETAIL,
    FONT_DETAIL_LIGHT,
    FONT_SCRIPT,
    GUTTER as GAP,
    HAIRLINE,
    MAT_GALLERY as MAT,
    # ROSE_GOLD is read by the chrome tests through this module's
    # namespace rather than by the template itself, so the linter
    # cannot see the use.
    ROSE_GOLD,  # noqa: F401
    TEXT_DARK,
)
from .brand_text import detail_lines
from .layout_sidecar import layout_sidecar_path

# HAIRLINE frames each print, matching the collage.
#
# MAT and GAP are the gallery mat, also matching the collage: an even cream
# border with real gutters. The gaps used to be filled with a warmer
# 240,235,228 while every other template used the brand cream, which left this
# the one off-brand surface.


# === Layout, specific to this template ===

CANVAS_W = 1080
CANVAS_H = 1920
FPS = 30

ROW_GAP = GAP          # gap between rows
COL_GAP = GAP          # gap between photos in a row
SIDE_MARGIN = MAT      # kept as an alias; the mat is the side margin

# Row patterns — fewer heroes, more pairs/trios for even density
ROW_SIZES = [2, 3, 2, 3, 2, 3, 3, 1, 2, 3, 2, 3]  # hero every ~8th row

# Max height cap for hero (single photo) rows — prevents them dominating
HERO_MAX_H = 480
# Portrait heroes need more vertical room to read as hero rather than squashed.
# 65% of canvas height feels impactful without swallowing the scroll.
HERO_MAX_H_PORTRAIT = int(CANVAS_H * 0.65)

# Scroll timing
SCROLL_DURATION = 40.0   # seconds to scroll the full strip
HOLD_END = 1.0           # hold at bottom before closing
CLOSING_FRAME_DURATION = 5.0

# Branded chrome
HEADER_H = 220
# The footer is only a cream mask now: it softens photos scrolling in at the bottom
# edge. The colophon no longer lives here (it is baked into the strip right under
# the last photo), so this is back to a thin band.
FOOTER_H = 100
# Wide enough to read as the signature under the gallery without spanning the full
# mat, which felt like a banner. The asset carries transparent side margins, so its
# visible ink is a bit under this.
LOGO_WIDTH = 800
# The colophon sits in the strip, tucked right under the last print: a small gap
# above it, then even breathing room below before the frame's bottom mask.
COLOPHON_GAP_ABOVE = 24
COLOPHON_GAP_BELOW = 56

# The brand wordmark baked into the strip under the photos. The cream footer is the
# mask this reads best against, so it is the dark mark.
_ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
DEFAULT_LOGO = str(_ASSETS_DIR / "logo-black.png")

# Audio
AUDIO_FADE_DURATION = 5.0




def load_logo(logo_path: str | None) -> Image.Image | None:
    """The wordmark scaled to LOGO_WIDTH, or None if no mark was asked for.

    A path that is set and not on disk raises rather than returning None: this
    used to swallow it and scroll a strip with no signature (#334).
    """
    from .wordmark import load
    return load(logo_path, LOGO_WIDTH)


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
    logo_path: str | None = DEFAULT_LOGO,
):
    """Build a tall collage strip from photos arranged in masonry rows.

    crop_offsets: optional list of (x, y, zoom) triples in [-1, 1] / [≥1]
                  parallel to photo_paths. Default (0, 0, 1) = centred fill.
    return_layout: when True, returns (strip_image, cells) where cells is a
                   list of {photo_path, x, y, w, h} dicts in strip-pixel
                   coordinates — used by the app to overlay crop controls.
    logo_path: the colophon baked into the cream right under the last print.
               None draws no mark. Defaults to the brand dark wordmark so the
               editor preview and the video render show the same thing.
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

        # Cap hero rows so they don't dominate scroll time. Portraits get a
        # taller cap so a single portrait reads as a hero instead of a stripe.
        if photos_in_row == 1:
            cap = HERO_MAX_H_PORTRAIT if ratios[0] < 1.0 else HERO_MAX_H
            if natural_h > cap:
                natural_h = cap

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

    # The colophon is baked into the strip right under the last print, so the
    # bottom padding has to reserve room for it: a gap under the photos, the mark,
    # then even breathing room and the frame's bottom mask below it.
    logo = load_logo(logo_path)
    top_pad = HEADER_H + ROW_GAP * 3  # extra breathing room below header
    if logo:
        bottom_pad = (COLOPHON_GAP_ABOVE + logo.height
                      + COLOPHON_GAP_BELOW + FOOTER_H)
    else:
        bottom_pad = FOOTER_H + 30
    total_h = top_pad + sum(h for _, h, _ in row_data) + ROW_GAP * (len(row_data) - 1) + bottom_pad

    # Create strip on the brand cream mat
    strip = Image.new("RGB", (CANVAS_W, total_h), CREAM)
    strip_draw = ImageDraw.Draw(strip)

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
                ox, oy, oz = DEFAULT_CROP_OFFSET
            cropped = _crop_to_fill(
                photos[photo_idx], widths[col_idx], row_h, ox, oy, oz,
            )
            strip.paste(cropped, (x, y))
            # Hairline just OUTSIDE the cell, so it frames the print without
            # eating a row of the photograph (same ring as the collage).
            strip_draw.rectangle(
                [x - 1, y - 1, x + widths[col_idx], y + row_h],
                outline=HAIRLINE, width=1,
            )
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

    # Colophon: the wordmark tucked right under the last print, centred on the mat.
    if logo and cells:
        last_photo_bottom = max(c["y"] + c["h"] for c in cells)
        logo_x = (CANVAS_W - logo.width) // 2
        logo_y = last_photo_bottom + COLOPHON_GAP_ABOVE
        strip.paste(logo, (logo_x, logo_y), logo)

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

    title_font = load_font(FONT_SCRIPT, 70)
    detail_font = load_font(FONT_DETAIL, 26, index=FONT_DETAIL_LIGHT)
    bbox = draw.textbbox((0, 0), event_name, font=title_font)
    tw = bbox[2] - bbox[0]
    draw.text(((CANVAS_W - tw) // 2, 35), event_name, font=title_font, fill=TEXT_DARK)

    title_h = bbox[3] - bbox[1]
    info_y = 35 + title_h + 20
    for j, line in enumerate(detail_lines(event_name, org, venue)):
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

    if logo:
        lx = (CANVAS_W - logo.width) // 2
        ly = footer_y + (FOOTER_H - logo.height) // 2
        frame_rgba.paste(logo, (lx, ly), logo)

    return frame_rgba.convert("RGB")


from postroll.ai.audio_tags import THURSDAY_FALLBACK_TAGS as _DEFAULT_AUDIO_TAGS  # noqa: E402


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

    layout_path = layout_sidecar_path(output)
    with open(layout_path, "w") as lf:
        json.dump({
            "strip_width":  strip.width,
            "strip_height": strip.height,
            "cells":        cells,
        }, lf)

    print(f"Reel preview written: {output} ({strip.width}x{strip.height}, {len(cells)} cells)")
    return str(output)


def resolve_reel_audio(
    *,
    audio_path: str | None,
    pieces: list[dict] | None,
    audio_tags: str,
    on_warning=None,
) -> str | None:
    """Which track the Thursday reel uses, and a word when it is not the one
    the programme asked for (#450).

    The programme match degraded to generic tag music on a bare
    `except Exception`: no line on stderr and no entry in the warnings channel
    the pipeline has carried since #265, so a Jamendo outage or a bug in
    `fetch_audio_by_program` turned every Thursday reel's programme-matched
    track into mood music while the run reported clean. `audio.py` built the
    distinct `JamendoUnavailable` type precisely so callers could tell that
    apart from a programme nothing matched, and this caller erased it.

    A programme that genuinely matched nothing stays silent. That is the
    ordinary outcome for repertoire Jamendo does not carry, and a warning on an
    ordinary outcome is one nobody reads (L36).
    """
    if audio_path is not None:
        return audio_path

    from postroll import audio as audio_module

    def warn(message: str) -> None:
        print(f"warning: {message}", file=sys.stderr, flush=True)
        if on_warning is not None:
            on_warning(message)

    if pieces:
        try:
            audio_path = audio_module.fetch_audio_by_program(pieces)
        except audio_module.JamendoUnavailable as e:
            warn(f"The programme-matched music could not be fetched: {e} "
                 "This reel uses generic tag-matched music instead.")
        except Exception as e:
            warn(f"Searching the programme for music failed: {e}. "
                 "This reel uses generic tag-matched music instead.")

    if audio_path is None:
        audio_path = audio_module.fetch_audio(audio_tags)
    return audio_path


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
    pieces: list[dict] | None = None,  # OCR program pieces — for piece-match auto-fetch
    crop_offsets: list[tuple[float, float, float]] | None = None,
    on_warning=None,  # called with a sentence when the reel had to settle for less
) -> str:
    """Generate a photo scroll reel with masonry collage layout.

    scroll_duration: seconds to scroll the full strip (default 40.0).
    audio_tags: comma-separated Jamendo tags; overrides _DEFAULT_AUDIO_TAGS when provided.
    pieces: OCR program pieces. If audio_path is None, we'll try to find a
            Jamendo recording of one of the program pieces before falling
            back to the tag-based search.
    crop_offsets: optional per-photo (x, y, zoom) triples — lets the Thursday
                  editor override the default centred fill on a per-photo basis.
    on_warning: called with one sentence when the reel rendered but had to
                settle for something other than what was asked for, so the
                caller can put it in the run's warnings rather than the reel
                degrading in silence (#450).
    """
    audio_path = resolve_reel_audio(
        audio_path=audio_path, pieces=pieces,
        audio_tags=audio_tags or _DEFAULT_AUDIO_TAGS,
        on_warning=on_warning,
    )

    # photo_paths is the source of truth — sorted once at import time on the
    # Swift side. Do NOT re-sort here: any user reorder (e.g. the Thursday
    # swap-photos feature) lives in this array and re-sorting silently
    # discards it, producing an MP4 that disagrees with the strip PNG +
    # layout JSON written by build_reel_preview (which doesn't sort).
    from pathlib import Path as _Path
    print(f"[generate_reel_scroll] photos in order ({len(photo_paths)}):", flush=True)
    for i, p in enumerate(photo_paths):
        print(f"  [{i}] {_Path(p).name}", flush=True)

    n = len(photo_paths)

    # Build collage strip
    print(f"Building collage strip from {n} photos...")
    strip = build_collage_strip(
        photo_paths, seed=seed, crop_offsets=crop_offsets, logo_path=logo_path,
    )
    strip_h = strip.height
    print(f"Strip size: {CANVAS_W}x{strip_h}")

    # A strip shorter than the canvas (possible with a handful of photos)
    # has nothing to scroll: cropping past its bottom would render a black
    # band, and a 40 second motionless "scroll" is dead air. Pad the strip
    # to canvas height with the cream background and collapse the scroll
    # phase to a short hold instead.
    if strip_h <= CANVAS_H:
        padded = Image.new("RGB", (CANVAS_W, CANVAS_H), CREAM)
        padded.paste(strip, (0, 0))
        strip = padded
        strip_h = CANVAS_H
        scroll_duration = min(scroll_duration, 4.0)
        print(f"Strip shorter than canvas: padded to {CANVAS_W}x{CANVAS_H}, "
              f"scroll collapsed to {scroll_duration}s hold")

    total_duration = scroll_duration + HOLD_END + CLOSING_FRAME_DURATION

    # Scroll exactly to bottom of strip — bottom_pad handles footer clearance.
    # When the strip exactly fills the canvas this is 0 (a static frame).
    max_scroll = max(0, strip_h - CANVAS_H)

    # The colophon is baked into the strip (above), so the footer chrome is just a
    # cream mask now: pass no logo to it.

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
                frame = draw_branded_chrome(frame, event_name, org, venue, None)

            elif i < scroll_frames + hold_frames:
                frame = strip.crop((0, max_scroll, CANVAS_W, max_scroll + CANVAS_H))
                frame = draw_branded_chrome(frame, event_name, org, venue, None)

            else:
                if closing_frame:
                    closing_i = i - scroll_frames - hold_frames
                    if closing_i < FPS:
                        blend = closing_i / FPS
                        last = strip.crop((0, max_scroll, CANVAS_W, max_scroll + CANVAS_H))
                        last = draw_branded_chrome(last, event_name, org, venue, None)
                        frame = Image.blend(last, closing_frame, blend)
                    else:
                        frame = closing_frame
                else:
                    frame = strip.crop((0, max_scroll, CANVAS_W, max_scroll + CANVAS_H))
                    frame = draw_branded_chrome(frame, event_name, org, venue, None)

            frame.save(str(tmpdir / f"frame_{i:05d}.png"), "PNG")

        # Encode to a temp name and rename into place atomically: a cancelled
        # render orphans its ffmpeg child, which can keep writing for seconds
        # while a replacement encode targets the same final path. The pid
        # suffix keeps the two encodes from sharing a temp file either.
        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)
        encode_tmp = output.with_suffix(f".{os.getpid()}.tmp.mp4")

        # Fit the audio to the reel length first: short tracks are looped with
        # crossfaded seams (no jarring restart) rather than padded with silence.
        # On any failure, fall back to the raw track with a plain trim/pad.
        from .audio_fit import fit_audio_to_duration
        fade = f"afade=t=out:st={total_duration - AUDIO_FADE_DURATION}:d={AUDIO_FADE_DURATION}"
        try:
            audio_in = fit_audio_to_duration(
                audio_path, str(tmpdir / "audio_fit.wav"), duration=total_duration,
            )
            audio_af = fade
        except Exception as e:
            print(f"[generate_reel_scroll] audio fit failed, using raw track: {e}",
                  file=sys.stderr)
            audio_in = audio_path
            audio_af = f"atrim=0:{total_duration},{fade},apad"

        cmd = [
            "ffmpeg", "-y",
            "-framerate", str(FPS),
            "-i", str(tmpdir / "frame_%05d.png"),
            "-i", audio_in,
            # Select streams explicitly: without -map, ffmpeg picks the
            # highest resolution video stream across all inputs, and MP3
            # cover art counts, which can replace the reel with album art.
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-af", audio_af,
            "-t", str(total_duration),
            str(encode_tmp),
        ]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            encode_tmp.unlink(missing_ok=True)
            raise RuntimeError(f"ffmpeg failed: {result.stderr[-500:]}")
        os.replace(encode_tmp, output)

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
