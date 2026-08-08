"""
PostRoll — Slider Reveal Reel Generator

Creates a 1080x1920 vertical reel that reveals the edited photo over the RAW
with a sweeping vertical divider line. Zero manual effort — just needs the
RAW photo, edited photo, and audio file.

Layout:
    - Starts showing full RAW photo
    - Vertical divider sweeps left to right, revealing edit behind it
    - Holds on full edit for a moment
    - Closes on before/after static frame
    - Audio trimmed and faded to match duration

Usage:
    python generate_reel_slider.py \
        --raw photo_raw.jpg --edit photo_edit.jpg \
        --audio music.m4a --output output/reel.mp4
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter


# === Design Tokens ===

CANVAS_W = 1080
CANVAS_H = 1920
FPS = 30

# Timing
HOLD_RAW = 1.5           # hold on RAW with branded chrome
REVEAL_DURATION = 5.0    # slider sweep
HOLD_EDIT_DURATION = 1.5  # hold on edit
TRANSITION_DURATION = 1.5  # crossfade to closing frame
CLOSING_FRAME_DURATION = 3.0
TOTAL_DURATION = HOLD_RAW + REVEAL_DURATION + HOLD_EDIT_DURATION + TRANSITION_DURATION + CLOSING_FRAME_DURATION

# Divider line
DIVIDER_WIDTH = 3
DIVIDER_COLOR = (255, 255, 255)
GAP = 6  # thin gap between triptych strips

# Ken Burns zoom — disabled (was causing visible shaking)
ZOOM_START = 1.0
ZOOM_END = 1.0

# Branded chrome (matching before/after template)
CREAM = (252, 250, 247)
CREAM_OPACITY = 210
TEXT_DARK = (60, 55, 50)
ROSE_GOLD = (160, 105, 95)
HEADER_H = 340  # cream header with event info — tall enough to push title clear of the iPhone notch / Dynamic Island
TITLE_TOP_Y = 170  # clears notch (~120px) + Dynamic Island with breathing room
FOOTER_H = 100  # cream footer with logo
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"

# RAW desaturation — disabled (photos should be shown unaltered)
RAW_DESATURATION = 0.0  # 0 = full color, 1 = grayscale

# Labels
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"
# Light, not Thin: the detail line rendered spindly in Thin (the .ttc Thin face).
FONT_DETAIL_LIGHT = 7
FONT_DETAIL_BOLD = 1  # RAW/Edit labels need to read at Instagram phone size; Thin disappears
# RAW/Edit labels sit on the cream mat now, so they are dark. They used to be white,
# which only worked against the old blurred, darkened photo background.
LABEL_COLOR = TEXT_DARK
LABEL_FONT_SIZE = 38
LABEL_MARGIN = 30
LOGO_WIDTH = 200

# Audio
AUDIO_FADE_DURATION = 2.0  # fade out in last 2 seconds


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        return ImageFont.load_default()


def prepare_photo_simple(photo: Image.Image, edit_photo: Image.Image) -> tuple[Image.Image, int]:
    """Fit photo to width on a flat cream background. Returns (canvas, photo_y).

    edit_photo is kept for signature compatibility but no longer used: the
    letterbox is brand cream (gallery style), not a blurred copy of the edit.
    """
    photo_ratio = photo.width / photo.height
    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), CREAM)

    # Fit photo to width, center vertically
    fit_w = CANVAS_W
    fit_h = int(CANVAS_W / photo_ratio)
    resized = photo.resize((fit_w, fit_h), Image.LANCZOS)
    py = (CANVAS_H - fit_h) // 2
    canvas.paste(resized, (0, py))

    return canvas, py


def prepare_stacked_after(
    color_photo: Image.Image,
    bw_photo: Image.Image,
    bg_photo: Image.Image,
) -> Image.Image:
    """Build the 'after' canvas for 3-photo mode: the color edit stacked above
    the B&W edit, both fit within the clear area between the reel's header and
    footer on a blurred background. Used as the slider's reveal target so both
    afters are visible at once. Each photo fits to its own aspect, so the B&W
    can be a different crop than the color.

    bg_photo is kept for signature compatibility but no longer used: the
    background is flat brand cream (gallery style).
    """
    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), CREAM)

    content_top = HEADER_H
    content_bottom = CANVAS_H - FOOTER_H
    gap = 8
    half_h = (content_bottom - content_top - gap) // 2

    for idx, photo in enumerate([color_photo, bw_photo]):
        ratio = photo.width / photo.height
        fit_w = CANVAS_W
        fit_h = int(fit_w / ratio)
        if fit_h > half_h:
            fit_h = half_h
            fit_w = int(fit_h * ratio)
        resized = photo.convert("RGB").resize((fit_w, fit_h), Image.LANCZOS)
        region_top = content_top + idx * (half_h + gap)
        px = (CANVAS_W - fit_w) // 2
        py = region_top + (half_h - fit_h) // 2
        canvas.paste(resized, (px, py))

    return canvas


def ease_in_out(t: float) -> float:
    """Dramatic ease — slow start, fast middle, slow end."""
    if t < 0.3:
        # Slow start
        return (t / 0.3) ** 2 * 0.15
    elif t < 0.7:
        # Fast middle
        mid = (t - 0.3) / 0.4
        return 0.15 + mid * 0.7
    else:
        # Slow end
        end = (t - 0.7) / 0.3
        return 0.85 + (1 - (1 - end) ** 2) * 0.15


def draw_branded_chrome(
    frame: Image.Image,
    event_name: str,
    org: str,
    venue: str,
    logo: Image.Image | None,
    photo_y: int,
    photo_h: int,
) -> Image.Image:
    """Draw cream header and footer with event info, matching before/after style."""
    frame_rgba = frame.convert("RGBA")

    # Cream header
    header = Image.new("RGBA", (CANVAS_W, HEADER_H), (*CREAM, CREAM_OPACITY))
    frame_rgba.paste(header, (0, 0), header)

    draw = ImageDraw.Draw(frame_rgba)

    # Title
    title_font = load_font(FONT_SCRIPT, 70)
    detail_font = load_font(FONT_DETAIL, 26, index=FONT_DETAIL_LIGHT)
    bbox = draw.textbbox((0, 0), event_name, font=title_font)
    tw = bbox[2] - bbox[0]
    tx = (CANVAS_W - tw) // 2
    draw.text((tx, TITLE_TOP_Y), event_name, font=title_font, fill=TEXT_DARK)

    # Org + Venue
    title_h = bbox[3] - bbox[1]
    info_y = TITLE_TOP_Y + title_h + 20
    for j, line in enumerate([org, venue]):
        if line:
            # Centered with letter spacing
            total_w = 0
            for ch in line:
                cb = draw.textbbox((0, 0), ch, font=detail_font)
                total_w += (cb[2] - cb[0]) + 6
            total_w -= 6
            x = (CANVAS_W - total_w) // 2
            for ch in line:
                draw.text((x, info_y + j * 36), ch, font=detail_font, fill=TEXT_DARK)
                cb = draw.textbbox((0, 0), ch, font=detail_font)
                x += (cb[2] - cb[0]) + 6

    # Cream footer
    footer_y = CANVAS_H - FOOTER_H
    footer = Image.new("RGBA", (CANVAS_W, FOOTER_H), (*CREAM, CREAM_OPACITY))
    frame_rgba.paste(footer, (0, footer_y), footer)

    # Logo in footer
    if logo:
        lx = (CANVAS_W - logo.width) // 2
        ly = footer_y + (FOOTER_H - logo.height) // 2
        frame_rgba.paste(logo, (lx, ly), logo)

    return frame_rgba.convert("RGB")


def desaturate(img: Image.Image, amount: float) -> Image.Image:
    """Desaturate an image. amount=0 is full color, 1 is grayscale."""
    from PIL import ImageEnhance
    enhancer = ImageEnhance.Color(img)
    return enhancer.enhance(1.0 - amount)


def apply_zoom(img: Image.Image, zoom: float) -> Image.Image:
    """Apply a center zoom crop to an image."""
    w, h = img.size
    new_w = int(w / zoom)
    new_h = int(h / zoom)
    left = (w - new_w) // 2
    top = (h - new_h) // 2
    cropped = img.crop((left, top, left + new_w, top + new_h))
    return cropped.resize((w, h), Image.LANCZOS)


def generate_frame(
    raw_canvas: Image.Image,
    edit_canvas: Image.Image,
    divider_x: int,
    font: ImageFont.FreeTypeFont,
    zoom: float = 1.0,
    logo: Image.Image | None = None,
    show_logo: bool = False,
    show_edit_label: bool = True,
) -> Image.Image:
    """Generate a single frame with effects.

    show_edit_label: suppressed in 3-photo mode, where the revealed side is a
    color-over-B&W composite and a single "Edit" label would be misleading.
    """
    # Apply zoom
    raw_zoomed = apply_zoom(raw_canvas, zoom) if zoom > 1.001 else raw_canvas
    edit_zoomed = apply_zoom(edit_canvas, zoom) if zoom > 1.001 else edit_canvas

    # Desaturate the RAW side
    raw_desat = desaturate(raw_zoomed, RAW_DESATURATION)

    frame = raw_desat.copy()

    # Reveal edit on the left side
    if divider_x > 0:
        edit_strip = edit_zoomed.crop((0, 0, min(divider_x, CANVAS_W), CANVAS_H))
        frame.paste(edit_strip, (0, 0))

    # Crisp white divider. No drop shadow: on the cream mat there is nothing to
    # divide (both sides are the same cream), so a shadow only streaks the mat.
    # Over the photo the white line still reads on its own.
    if 0 < divider_x < CANVAS_W:
        draw = ImageDraw.Draw(frame)
        draw.line(
            [(divider_x, 0), (divider_x, CANVAS_H)],
            fill=DIVIDER_COLOR, width=DIVIDER_WIDTH,
        )

    draw = ImageDraw.Draw(frame)

    # Labels animate with the swipe — slide in/out tied to divider position
    label_y = int(CANVAS_H * 0.75)

    # "Edit" label — revealed by the slider (clipped to left of divider)
    if show_edit_label and divider_x > LABEL_MARGIN:
        lx = LABEL_MARGIN

        # Dark text, no shadow: the label sits on the cream mat now, so white was
        # invisible and the drop shadow was the only thing showing.
        label_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
        ld = ImageDraw.Draw(label_layer)
        ld.text((lx, label_y), "E d i t", font=font, fill=(*LABEL_COLOR, 255))

        # Clip to left of divider
        mask = Image.new("L", (CANVAS_W, CANVAS_H), 0)
        md = ImageDraw.Draw(mask)
        md.rectangle([(0, 0), (divider_x, CANVAS_H)], fill=255)
        label_layer.putalpha(Image.composite(label_layer.split()[3], Image.new("L", (CANVAS_W, CANVAS_H), 0), mask))

        frame_rgba = frame.convert("RGBA")
        frame_rgba = Image.alpha_composite(frame_rgba, label_layer)
        frame = frame_rgba.convert("RGB")

    # "RAW" label — gets pushed off by the divider
    if divider_x < CANVAS_W - 60:
        raw_text = "R A W"
        draw_tmp = ImageDraw.Draw(frame)
        bbox = draw_tmp.textbbox((0, 0), raw_text, font=font)
        tw = bbox[2] - bbox[0]

        # Stays put until divider gets close, then slides right and fades
        distance_to_divider = CANVAS_W - LABEL_MARGIN - tw - divider_x
        if distance_to_divider > 200:
            # Divider is far — label stays in place
            lx = CANVAS_W - LABEL_MARGIN - tw
            label_alpha = 255
        else:
            # Divider is close — label slides right and fades
            push = max(0.0, 1.0 - distance_to_divider / 200)
            lx = int((CANVAS_W - LABEL_MARGIN - tw) + push * 100)
            label_alpha = int(255 * (1 - push))

        if label_alpha > 10:
            frame_rgba = frame.convert("RGBA")
            draw = ImageDraw.Draw(frame_rgba)
            draw.text((lx, label_y), raw_text, font=font, fill=(*LABEL_COLOR, label_alpha))
            frame = frame_rgba.convert("RGB")

    # Logo watermark during hold-on-edit
    if show_logo and logo:
        frame_rgba = frame.convert("RGBA")
        lx = CANVAS_W - 25 - logo.width
        ly = 25
        frame_rgba.paste(logo, (lx, ly), logo)
        frame = frame_rgba.convert("RGB")

    return frame


from postroll.ai.audio_tags import TUESDAY_DEFAULT_TAGS as _DEFAULT_AUDIO_TAGS  # noqa: E402
from .missing_media import require_present  # noqa: E402


def generate_reel_slider(
    raw_path: str,
    edit_path: str,
    audio_path: str | None,   # None = auto-fetch from Jamendo
    output_path: str,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    closing_frame_path: str | None = None,
    logo_path: str | None = None,
    bw_path: str | None = None,
) -> str:
    """Generate a slider reveal reel with branded chrome.

    Args:
        raw_path: Path to RAW photo
        edit_path: Path to edited photo
        audio_path: Path to audio file
        output_path: Where to save the MP4
        event_name: Event name for header
        org: Organization for header
        venue: Venue for header
        closing_frame_path: Optional path to before/after closing frame PNG
        logo_path: Optional path to DW logo for header/footer
        bw_path: Optional B&W after. When set, the slider reveals RAW into a
            color-over-B&W composite so both afters show at once (3-photo mode).
    """
    # Same check as the before/after graphic: a B&W that was chosen but is not
    # on disk is reported, never quietly dropped. Falling back to the two-photo
    # treatment here produced a plausible file that was not the one asked for,
    # so there was nothing to notice (#180).
    raw_path = require_present(raw_path, "RAW photo")
    edit_path = require_present(edit_path, "edited photo")
    bw_path = require_present(bw_path, "B&W photo")

    if audio_path is None:
        # Fail loud. This used to swallow the error and render a reel with no
        # audio track at all, which shipped silently to Instagram with nobody
        # any the wiser. A reel with no music is not a successful render.
        from postroll.audio import fetch_audio
        try:
            audio_path = fetch_audio(_DEFAULT_AUDIO_TAGS)
        except Exception as exc:
            raise RuntimeError(
                f"Could not resolve audio for the Tuesday reel: {exc}. "
                "Refusing to render a silent reel."
            ) from exc

    raw_photo = Image.open(raw_path)
    edit_photo = Image.open(edit_path)
    font = load_font(FONT_DETAIL, LABEL_FONT_SIZE, index=FONT_DETAIL_BOLD)

    # 3-photo mode: the revealed "after" is the color edit stacked over the B&W.
    three_photo = bool(bw_path)

    # Pre-render the before (RAW) at fit-to-width
    raw_canvas, photo_y = prepare_photo_simple(raw_photo, edit_photo)
    if three_photo:
        bw_photo = Image.open(bw_path)
        edit_canvas = prepare_stacked_after(edit_photo, bw_photo, edit_photo)
    else:
        edit_canvas, _ = prepare_photo_simple(edit_photo, edit_photo)
    photo_h = int(CANVAS_W / (raw_photo.width / raw_photo.height))
    show_edit = not three_photo

    # Load closing frame if provided
    closing_frame = None
    if closing_frame_path and Path(closing_frame_path).exists():
        closing_frame = Image.open(closing_frame_path).convert("RGB")
        closing_frame = closing_frame.resize((CANVAS_W, CANVAS_H), Image.LANCZOS)

    # Load logo for watermark during hold-on-edit
    logo = None
    if logo_path and Path(logo_path).exists():
        logo = Image.open(logo_path).convert("RGBA")
        logo_scale = LOGO_WIDTH / logo.width
        logo = logo.resize(
            (int(logo.width * logo_scale), int(logo.height * logo_scale)),
            Image.LANCZOS,
        )
        # Semi-transparent
        alpha = logo.split()[3]
        alpha = alpha.point(lambda p: int(p * 0.7))
        logo.putalpha(alpha)

    total_frames = int(TOTAL_DURATION * FPS)
    hold_raw_frames = int(HOLD_RAW * FPS)
    reveal_frames = int(REVEAL_DURATION * FPS)
    hold_edit_frames = int(HOLD_EDIT_DURATION * FPS)
    transition_frames = int(TRANSITION_DURATION * FPS)
    closing_frames = int(CLOSING_FRAME_DURATION * FPS)

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        for i in range(total_frames):
            global_t = i / total_frames
            zoom = ZOOM_START + (ZOOM_END - ZOOM_START) * global_t

            # Subtle Ken Burns zoom across duration
            raw_z = apply_zoom(raw_canvas, zoom) if zoom > 1.001 else raw_canvas
            edit_z = apply_zoom(edit_canvas, zoom) if zoom > 1.001 else edit_canvas

            phase_end_1 = hold_raw_frames
            phase_end_2 = phase_end_1 + reveal_frames
            phase_end_3 = phase_end_2 + hold_edit_frames
            phase_end_4 = phase_end_3 + transition_frames

            if i < phase_end_1:
                frame = generate_frame(raw_z, edit_z, 0, font, zoom=1.0, show_edit_label=show_edit)
                frame = draw_branded_chrome(
                    frame, event_name, org, venue, logo, photo_y, photo_h
                )

            elif i < phase_end_2:
                sweep_i = i - phase_end_1
                t = sweep_i / reveal_frames
                eased = ease_in_out(t)
                divider_x = int(eased * CANVAS_W)
                frame = generate_frame(raw_z, edit_z, divider_x, font, zoom=1.0, show_edit_label=show_edit)
                frame = draw_branded_chrome(
                    frame, event_name, org, venue, logo, photo_y, photo_h
                )

            elif i < phase_end_3:
                frame = generate_frame(raw_z, edit_z, CANVAS_W, font, zoom=1.0, show_edit_label=show_edit)
                frame = draw_branded_chrome(
                    frame, event_name, org, venue, logo, photo_y, photo_h
                )

            elif i < phase_end_4:
                # Crossfade to closing frame. Keep the reel chrome through
                # this transition — the previous "drop chrome to avoid ghost
                # text" approach produced a visible flash of unbranded photo
                # at the start of the crossfade. A brief overlap of reel
                # header and closing-frame header during the blend is far
                # less jarring than the flash.
                blend_t = ease_in_out((i - phase_end_3) / transition_frames)
                if closing_frame:
                    edit_frame = generate_frame(raw_z, edit_z, CANVAS_W, font, zoom=1.0, show_edit_label=show_edit)
                    edit_frame = draw_branded_chrome(
                        edit_frame, event_name, org, venue, logo, photo_y, photo_h
                    )
                    frame = Image.blend(edit_frame, closing_frame, blend_t)
                else:
                    edit_frame = generate_frame(raw_z, edit_z, CANVAS_W, font, zoom=1.0, show_edit_label=show_edit)
                    frame = draw_branded_chrome(
                        edit_frame, event_name, org, venue, logo, photo_y, photo_h
                    )

            else:
                # Hold closing frame
                if closing_frame:
                    frame = closing_frame
                else:
                    frame = generate_frame(raw_z, edit_z, CANVAS_W, font, zoom=1.0, show_edit_label=show_edit)
                    frame = draw_branded_chrome(
                        frame, event_name, org, venue, logo, photo_y, photo_h
                    )

            frame.save(str(tmpdir / f"frame_{i:05d}.png"), "PNG")

        # Encode to a temp name and rename into place atomically so a
        # cancelled render's orphaned ffmpeg can never corrupt the final file.
        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)
        encode_tmp = output.with_suffix(f".{os.getpid()}.tmp.mp4")

        if audio_path:
            # Fit the audio to the reel length: short tracks loop with
            # crossfaded seams (no jarring restart) instead of cutting the reel
            # short via -shortest. Fall back to the raw track if the fit fails.
            from .audio_fit import fit_audio_to_duration
            fade = f"afade=t=out:st={TOTAL_DURATION - AUDIO_FADE_DURATION}:d={AUDIO_FADE_DURATION}"
            try:
                audio_in = fit_audio_to_duration(
                    audio_path, str(tmpdir / "audio_fit.wav"), duration=TOTAL_DURATION,
                )
                audio_opts = ["-af", fade]
            except Exception as e:
                print(f"[generate_reel_slider] audio fit failed, using raw track: {e}",
                      file=sys.stderr)
                audio_in = audio_path
                audio_opts = ["-af", fade, "-shortest"]
            cmd = [
                "ffmpeg", "-y",
                "-framerate", str(FPS),
                "-i", str(tmpdir / "frame_%05d.png"),
                "-i", audio_in,
                # Explicit stream selection so MP3 cover art can never be
                # picked as the video stream.
                "-map", "0:v:0", "-map", "1:a:0",
                "-t", str(TOTAL_DURATION),
                *audio_opts,
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                str(encode_tmp),
            ]
        else:
            cmd = [
                "ffmpeg", "-y",
                "-framerate", str(FPS),
                "-i", str(tmpdir / "frame_%05d.png"),
                "-t", str(TOTAL_DURATION),
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                str(encode_tmp),
            ]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            encode_tmp.unlink(missing_ok=True)
            print(f"ffmpeg error: {result.stderr}")
            raise RuntimeError(f"ffmpeg failed: {result.stderr[-500:]}")
        os.replace(encode_tmp, output)

    print(f"Slider reel generated: {output} ({TOTAL_DURATION}s, {FPS}fps)")
    return str(output)


def main():
    parser = argparse.ArgumentParser(description="Generate a slider reveal reel")
    parser.add_argument("--raw", required=True, help="Path to RAW photo")
    parser.add_argument("--edit", required=True, help="Path to edited photo")
    parser.add_argument("--bw", default=None, help="Optional B&W after — reveals color over B&W (3-photo mode)")
    parser.add_argument("--audio", default=None, help="Path to audio file (omit to auto-fetch from Jamendo)")
    parser.add_argument("--event", default="", help="Event name")
    parser.add_argument("--org", default="", help="Organization")
    parser.add_argument("--venue", default="", help="Venue")
    parser.add_argument("--closing-frame", default=None, help="Path to before/after PNG")
    parser.add_argument("--logo", default=None, help="Path to DW logo")
    parser.add_argument("--output", default="output/reel_slider.mp4")
    args = parser.parse_args()

    generate_reel_slider(
        raw_path=args.raw,
        edit_path=args.edit,
        audio_path=args.audio,
        output_path=args.output,
        event_name=args.event,
        org=args.org,
        venue=args.venue,
        closing_frame_path=args.closing_frame,
        logo_path=args.logo,
        bw_path=args.bw,
    )


if __name__ == "__main__":
    main()
