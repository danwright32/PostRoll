"""
PostRoll — Split Compare Reel Generator

Creates a 1080x1920 vertical reel that splits the frame to show RAW and Edit
side by side, then lets the edit fill the frame. Distinct from the slider
reveal — this opens from the center and has a comparison moment.

Flow: Hold RAW → split opens from center → hold comparison → edit fills frame
    → closing frame

Usage:
    python generate_reel_morph.py \
        --raw photo_raw.jpg --edit photo_edit.jpg \
        --audio music.m4a --output output/reel.mp4
"""

from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageEnhance


# === Design Tokens ===

CANVAS_W = 1080
CANVAS_H = 1920
FPS = 30

# Timing
HOLD_RAW = 1.5            # hold on RAW
SPLIT_DURATION = 5.0      # continuous split from center to full edit — no pause
HOLD_EDIT = 1.5           # hold on full edit
TRANSITION_DURATION = 1.5  # crossfade to closing
CLOSING_FRAME_DURATION = 3.0
TOTAL_DURATION = (HOLD_RAW + SPLIT_DURATION + HOLD_EDIT +
                  TRANSITION_DURATION + CLOSING_FRAME_DURATION)

# RAW treatment
RAW_DESATURATION = 0.0
RAW_DARKEN = 1.0
RAW_COOL_SHIFT = 0

# Ken Burns — disabled (was causing visible shaking)
ZOOM_START = 1.0
ZOOM_END = 1.0

# Split divider
DIVIDER_WIDTH = 4
DIVIDER_COLOR = (255, 255, 255)

# Labels
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"
FONT_DETAIL_THIN = 12
LABEL_FONT_SIZE = 38
LABEL_MARGIN = 30

# Branded chrome
CREAM = (252, 250, 247)
CREAM_OPACITY = 210
TEXT_DARK = (60, 55, 50)
ROSE_GOLD = (160, 105, 95)
HEADER_H = 340  # tall enough to push title clear of the iPhone notch / Dynamic Island
TITLE_TOP_Y = 170  # clears notch (~120px) + Dynamic Island with breathing room
FOOTER_H = 100
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"
LOGO_WIDTH = 200

# Background
BG_BLUR_RADIUS = 50

# Audio
AUDIO_FADE_DURATION = 2.0


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        return ImageFont.load_default()


def prepare_photo(photo: Image.Image, bg_photo: Image.Image) -> Image.Image:
    """Fit photo to width on blurred edit background."""
    photo_ratio = photo.width / photo.height
    canvas_ratio = CANVAS_W / CANVAS_H
    if bg_photo.width / bg_photo.height > canvas_ratio:
        bg_scale = CANVAS_H / bg_photo.height
    else:
        bg_scale = CANVAS_W / bg_photo.width
    bg_w = int(bg_photo.width * bg_scale)
    bg_h = int(bg_photo.height * bg_scale)
    bg = bg_photo.resize((bg_w, bg_h), Image.LANCZOS)
    bg_left = (bg_w - CANVAS_W) // 2
    bg_top = (bg_h - CANVAS_H) // 2
    bg = bg.crop((bg_left, bg_top, bg_left + CANVAS_W, bg_top + CANVAS_H))
    bg = bg.filter(ImageFilter.GaussianBlur(radius=BG_BLUR_RADIUS))
    canvas = bg.convert("RGB")

    fit_w = CANVAS_W
    fit_h = int(CANVAS_W / photo_ratio)
    resized = photo.resize((fit_w, fit_h), Image.LANCZOS)
    py = (CANVAS_H - fit_h) // 2
    canvas.paste(resized, (0, py))
    return canvas


def apply_zoom(img: Image.Image, zoom: float) -> Image.Image:
    if zoom <= 1.001:
        return img
    w, h = img.size
    new_w = int(w / zoom)
    new_h = int(h / zoom)
    left = (w - new_w) // 2
    top = (h - new_h) // 2
    return img.crop((left, top, left + new_w, top + new_h)).resize((w, h), Image.LANCZOS)


def draw_branded_chrome(frame, event_name, org, venue, logo):
    """Draw cream header and footer."""
    frame_rgba = frame.convert("RGBA")
    header = Image.new("RGBA", (CANVAS_W, HEADER_H), (*CREAM, CREAM_OPACITY))
    frame_rgba.paste(header, (0, 0), header)
    draw = ImageDraw.Draw(frame_rgba)
    draw.line([(0, HEADER_H - 1), (CANVAS_W, HEADER_H - 1)], fill=ROSE_GOLD, width=2)

    title_font = load_font(FONT_SCRIPT, 70)
    detail_font = load_font(FONT_DETAIL, 26, index=FONT_DETAIL_THIN)
    bbox = draw.textbbox((0, 0), event_name, font=title_font)
    tw = bbox[2] - bbox[0]
    draw.text(((CANVAS_W - tw) // 2, TITLE_TOP_Y), event_name, font=title_font, fill=TEXT_DARK)

    title_h = bbox[3] - bbox[1]
    info_y = TITLE_TOP_Y + title_h + 20
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
    footer = Image.new("RGBA", (CANVAS_W, FOOTER_H), (*CREAM, CREAM_OPACITY))
    frame_rgba.paste(footer, (0, footer_y), footer)
    draw = ImageDraw.Draw(frame_rgba)
    draw.line([(0, footer_y), (CANVAS_W, footer_y)], fill=ROSE_GOLD, width=2)
    if logo:
        lx = (CANVAS_W - logo.width) // 2
        ly = footer_y + (FOOTER_H - logo.height) // 2
        frame_rgba.paste(logo, (lx, ly), logo)
    return frame_rgba.convert("RGB")


def draw_label(frame, text, x, y, font, alpha=255):
    """Draw a label with shadow."""
    shadow = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.text((x, y), text, font=font, fill=(0, 0, 0, min(120, alpha)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=3))
    f = frame.convert("RGBA")
    f = Image.alpha_composite(f, shadow)
    draw = ImageDraw.Draw(f)
    draw.text((x, y), text, font=font, fill=(255, 255, 255, alpha))
    return f.convert("RGB")


def ease_in_out(t):
    return t * t * (3 - 2 * t)


def generate_split_frame(
    raw_canvas: Image.Image,
    edit_canvas: Image.Image,
    split_progress: float,
    font: ImageFont.FreeTypeFont,
) -> Image.Image:
    """Generate a frame with the split view.

    split_progress: 0.0 = full RAW, 0.5 = 50/50 split, 1.0 = full edit
    """
    center = CANVAS_W // 2

    if split_progress >= 1.0:
        return edit_canvas.copy()

    center = CANVAS_W // 2
    half_gap = int(center * split_progress)

    frame = raw_canvas.copy()

    if half_gap > 0:
        # Show edit in the center portion
        right_start = center - half_gap
        right_end = center + half_gap

        if right_end > right_start:
            edit_strip = edit_canvas.crop((right_start, 0, right_end, CANVAS_H))
            frame.paste(edit_strip, (right_start, 0))

        # Divider lines at the split edges
        draw = ImageDraw.Draw(frame)
        if right_start > 0:
            draw.line([(right_start, 0), (right_start, CANVAS_H)],
                     fill=DIVIDER_COLOR, width=DIVIDER_WIDTH)
        if right_end < CANVAS_W:
            draw.line([(right_end, 0), (right_end, CANVAS_H)],
                     fill=DIVIDER_COLOR, width=DIVIDER_WIDTH)

    # Labels in the blurred area above photo
    label_y = int(CANVAS_H * 0.75)

    # RAW label — always visible, masked to RAW area once split starts
    raw_lx = LABEL_MARGIN
    left_divider = center - half_gap

    if left_divider > raw_lx:  # RAW area still covers the label
        shadow_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow_layer)
        sd.text((raw_lx, label_y), "R A W", font=font, fill=(0, 0, 0, 120))
        shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=3))

        label_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
        ld = ImageDraw.Draw(label_layer)
        ld.text((raw_lx, label_y), "R A W", font=font, fill=(255, 255, 255, 255))

        if half_gap > 0:
            # Mask to RAW area (left of left divider)
            mask = Image.new("L", (CANVAS_W, CANVAS_H), 0)
            md = ImageDraw.Draw(mask)
            md.rectangle([(0, 0), (left_divider, CANVAS_H)], fill=255)
            shadow_layer.putalpha(Image.composite(shadow_layer.split()[3], Image.new("L", (CANVAS_W, CANVAS_H), 0), mask))
            label_layer.putalpha(Image.composite(label_layer.split()[3], Image.new("L", (CANVAS_W, CANVAS_H), 0), mask))

        frame_rgba = frame.convert("RGBA")
        frame_rgba = Image.alpha_composite(frame_rgba, shadow_layer)
        frame_rgba = Image.alpha_composite(frame_rgba, label_layer)
        frame = frame_rgba.convert("RGB")

    # Edit label — revealed by the split opening, masked to the edit area
    edit_text = "E d i t"
    tmp_draw = ImageDraw.Draw(frame)
    eb = tmp_draw.textbbox((0, 0), edit_text, font=font)
    etw = eb[2] - eb[0]

    if half_gap > 10:
        # Label slides from center toward right side, following the split
        start_x = center + LABEL_MARGIN
        end_x = CANVAS_W - LABEL_MARGIN - etw
        edit_lx = int(start_x + (end_x - start_x) * split_progress)

        # Draw on separate layers, then clip to edit area
        label_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
        shadow_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow_layer)
        sd.text((edit_lx, label_y), edit_text, font=font, fill=(0, 0, 0, 120))
        shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=3))
        ld = ImageDraw.Draw(label_layer)
        ld.text((edit_lx, label_y), edit_text, font=font, fill=(255, 255, 255, 255))

        # Mask: only show within the edit area (between the dividers)
        left_edge = center - half_gap
        right_edge = center + half_gap
        mask = Image.new("L", (CANVAS_W, CANVAS_H), 0)
        md = ImageDraw.Draw(mask)
        md.rectangle([(left_edge, 0), (right_edge, CANVAS_H)], fill=255)

        shadow_layer.putalpha(Image.composite(shadow_layer.split()[3], Image.new("L", (CANVAS_W, CANVAS_H), 0), mask))
        label_layer.putalpha(Image.composite(label_layer.split()[3], Image.new("L", (CANVAS_W, CANVAS_H), 0), mask))

        frame_rgba = frame.convert("RGBA")
        frame_rgba = Image.alpha_composite(frame_rgba, shadow_layer)
        frame_rgba = Image.alpha_composite(frame_rgba, label_layer)
        frame = frame_rgba.convert("RGB")

    return frame


from postroll.ai.audio_tags import TUESDAY_DEFAULT_TAGS as _DEFAULT_AUDIO_TAGS  # noqa: E402


def generate_reel_morph(
    raw_path: str,
    edit_path: str,
    audio_path: str | None,   # None = auto-fetch from Jamendo
    output_path: str,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    closing_frame_path: str | None = None,
    logo_path: str | None = None,
) -> str:
    """Generate a split compare reel."""
    if audio_path is None:
        try:
            from postroll.audio import fetch_audio
            audio_path = fetch_audio(_DEFAULT_AUDIO_TAGS)
        except Exception:
            audio_path = None

    raw_photo = Image.open(raw_path)
    edit_photo = Image.open(edit_path)
    font = load_font(FONT_DETAIL, LABEL_FONT_SIZE, index=FONT_DETAIL_THIN)

    raw_canvas = prepare_photo(raw_photo, edit_photo)
    edit_canvas = prepare_photo(edit_photo, edit_photo)

    # No RAW treatment — show the actual RAW as-is

    closing_frame = None
    if closing_frame_path and Path(closing_frame_path).exists():
        closing_frame = Image.open(closing_frame_path).convert("RGB")
        closing_frame = closing_frame.resize((CANVAS_W, CANVAS_H), Image.LANCZOS)

    logo = None
    if logo_path and Path(logo_path).exists():
        logo = Image.open(logo_path).convert("RGBA")
        logo_scale = LOGO_WIDTH / logo.width
        logo = logo.resize(
            (int(logo.width * logo_scale), int(logo.height * logo_scale)),
            Image.LANCZOS,
        )

    total_frames = int(TOTAL_DURATION * FPS)
    p1 = int(HOLD_RAW * FPS)
    p2 = p1 + int(SPLIT_DURATION * FPS)
    p3 = p2 + int(HOLD_EDIT * FPS)
    p4 = p3 + int(TRANSITION_DURATION * FPS)

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        for i in range(total_frames):
            global_t = i / total_frames
            zoom = ZOOM_START + (ZOOM_END - ZOOM_START) * global_t
            raw_z = apply_zoom(raw_canvas, zoom)
            edit_z = apply_zoom(edit_canvas, zoom)

            if i < p1:
                # Hold on RAW
                frame = generate_split_frame(raw_z, edit_z, 0.0, font)

            elif i < p2:
                # Continuous split from center to full edit
                t = (i - p1) / (p2 - p1)
                split = ease_in_out(t)
                frame = generate_split_frame(raw_z, edit_z, split, font)

            elif i < p3:
                # Hold on full edit
                frame = edit_z.copy()
                edit_text = "E d i t"
                tmp_draw = ImageDraw.Draw(frame)
                eb = tmp_draw.textbbox((0, 0), edit_text, font=font)
                etw = eb[2] - eb[0]
                frame = draw_label(frame, edit_text,
                                  CANVAS_W - LABEL_MARGIN - etw,
                                  int(CANVAS_H * 0.75), font)

            elif i < p4:
                # Crossfade to closing frame. Keep the reel chrome on the
                # outgoing edit_z — the prior "drop chrome to avoid ghost
                # text" approach produced a visible flash of unbranded photo
                # at the start of the crossfade. Brief header overlap during
                # the blend reads cleaner than the flash.
                blend_t = ease_in_out((i - p3) / (p4 - p3))
                if closing_frame:
                    branded = draw_branded_chrome(edit_z.copy(), event_name, org, venue, logo)
                    frame = Image.blend(branded, closing_frame, blend_t)
                else:
                    frame = draw_branded_chrome(edit_z.copy(), event_name, org, venue, logo)

            else:
                # Hold closing frame — chrome is already baked in; don't overdraw.
                if closing_frame:
                    frame = closing_frame.copy()
                else:
                    frame = draw_branded_chrome(edit_z.copy(), event_name, org, venue, logo)

            # Apply chrome only during the reel phases (before the crossfade).
            if i < p3:
                frame = draw_branded_chrome(frame, event_name, org, venue, logo)
            frame.save(str(tmpdir / f"frame_{i:05d}.png"), "PNG")

        # Encode to a temp name and rename into place atomically so a
        # cancelled render's orphaned ffmpeg can never corrupt the final file.
        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)
        encode_tmp = output.with_suffix(f".{os.getpid()}.tmp.mp4")

        if audio_path:
            cmd = [
                "ffmpeg", "-y",
                "-framerate", str(FPS),
                "-i", str(tmpdir / "frame_%05d.png"),
                "-i", audio_path,
                # Explicit stream selection so MP3 cover art can never be
                # picked as the video stream.
                "-map", "0:v:0", "-map", "1:a:0",
                "-t", str(TOTAL_DURATION),
                "-af", f"afade=t=out:st={TOTAL_DURATION - AUDIO_FADE_DURATION}:d={AUDIO_FADE_DURATION}",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-shortest",
                str(encode_tmp),
            ]
        else:
            cmd = [
                "ffmpeg", "-y",
                "-framerate", str(FPS),
                "-i", str(tmpdir / "frame_%05d.png"),
                "-t", str(TOTAL_DURATION),
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                str(encode_tmp),
            ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            encode_tmp.unlink(missing_ok=True)
            raise RuntimeError(f"ffmpeg failed: {result.stderr[-500:]}")
        os.replace(encode_tmp, output)

    print(f"Split compare reel generated: {output} ({TOTAL_DURATION}s, {FPS}fps)")
    return str(output)


def main():
    parser = argparse.ArgumentParser(description="Generate a split compare reel")
    parser.add_argument("--raw", required=True)
    parser.add_argument("--edit", required=True)
    parser.add_argument("--audio", default=None, help="Path to audio file (omit to auto-fetch from Jamendo)")
    parser.add_argument("--event", default="")
    parser.add_argument("--org", default="")
    parser.add_argument("--venue", default="")
    parser.add_argument("--closing-frame", default=None)
    parser.add_argument("--logo", default=None)
    parser.add_argument("--output", default="output/reel_split.mp4")
    args = parser.parse_args()

    generate_reel_morph(
        raw_path=args.raw,
        edit_path=args.edit,
        audio_path=args.audio,
        output_path=args.output,
        event_name=args.event,
        org=args.org,
        venue=args.venue,
        closing_frame_path=args.closing_frame,
        logo_path=args.logo,
    )


if __name__ == "__main__":
    main()
