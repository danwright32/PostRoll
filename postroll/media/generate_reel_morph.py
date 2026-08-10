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
import sys
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

from .design_tokens import (
    CREAM,
    CREAM_EDGE,
    DIVIDER_WHITE as DIVIDER_COLOR,
    FONT_DETAIL,
    FONT_DETAIL_BOLD,
    FONT_DETAIL_LIGHT,
    FONT_DETAIL_MEDIUM,
    FONT_SCRIPT,
    MAT_PRINT as MAT,
    ROSE_GOLD,
    TEXT_DARK,
    WARM_MID,
)
from .brand_text import detail_lines


# === Layout, specific to this template ===

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

# Split divider (drawn only within the print)
DIVIDER_WIDTH = 4

# === Program-plate composition (the approved Tuesday reel look) ===
# A printed-program page: masthead top-left, the photo matted and hung as a print,
# a two-line caption placard below it, and a footer colophon closing the bottom.
# ROSE_GOLD is the one accent here: rules plus the live state word.

PRINT_W = CANVAS_W - 2 * MAT
MASTHEAD_Y = 176               # SignPainter title
VENUE_Y = 285
RULE_Y = 338
PRINT_Y = 430                  # the print is hung here
FOOTER_RULE_Y = CANVAS_H - 214  # colophon rule; logo centred beneath
LOGO_WIDTH = 340

# Set once per reel from the photo's aspect (raw and edit share it).
_PRINT_H = 624

# The caption is a two-line placard matching the Friday before/after wording, and it
# crossfades from BEFORE to AFTER on the wipe's curve. The wording map is imported so
# it can never drift from the closing frame.
from .generate_before_after import placard_text  # noqa: E402
BEFORE_STATE, AFTER_STATE = "RAW", "Edit"
BEFORE_ALPHA = 1.0
AFTER_ALPHA = 0.0

# Audio
AUDIO_FADE_DURATION = 2.0


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        return ImageFont.load_default()


def _tracked(draw, text, font, fill, x, y, spacing):
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        b = draw.textbbox((0, 0), ch, font=font)
        x += (b[2] - b[0]) + spacing


def prepare_photo(photo: Image.Image, bg_photo: Image.Image) -> Image.Image:
    """Hang the photo as a matted print on the cream mat.

    A soft drop shadow and a cream hairline make it read as a print on paper. Both
    the RAW and Edit canvases use the SAME print rectangle, so the split wipe (which
    reveals the edit's centre strip) only shows where there is a print to divide;
    the surrounding mat is cream-over-cream and stays still. bg_photo is unused.
    """
    global _PRINT_H
    _PRINT_H = int(PRINT_W / (photo.width / photo.height))

    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (*CREAM, 255))
    shadow = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rectangle(
        [MAT + 3, PRINT_Y + 6, MAT + PRINT_W + 3, PRINT_Y + _PRINT_H + 8],
        fill=(60, 55, 50, 44))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))

    canvas.paste(photo.resize((PRINT_W, _PRINT_H), Image.LANCZOS).convert("RGBA"),
                 (MAT, PRINT_Y))
    ImageDraw.Draw(canvas).rectangle(
        [MAT - 1, PRINT_Y - 1, MAT + PRINT_W, PRINT_Y + _PRINT_H],
        outline=CREAM_EDGE, width=1)
    return canvas.convert("RGB")


def apply_zoom(img: Image.Image, zoom: float) -> Image.Image:
    if zoom <= 1.001:
        return img
    w, h = img.size
    new_w = int(w / zoom)
    new_h = int(h / zoom)
    left = (w - new_w) // 2
    top = (h - new_h) // 2
    return img.crop((left, top, left + new_w, top + new_h)).resize((w, h), Image.LANCZOS)


def _smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)  # smoothstep, matches the photo's ease


def set_caption_state(progress: float) -> None:
    """Dissolve the caption placard THROUGH EMPTY on the wipe's curve: BEFORE fades
    out, then AFTER fades in. A straight cross-dissolve would overlap two different
    words in one spot and read as garbled, so they never coexist."""
    global BEFORE_ALPHA, AFTER_ALPHA
    BEFORE_ALPHA = _smooth((0.48 - progress) / 0.18)
    AFTER_ALPHA = _smooth((progress - 0.52) / 0.18)


def _draw_placard(canvas_rgba, state, alpha):
    if alpha <= 0.003:
        return canvas_rgba
    word, subtitle = placard_text(state)
    layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    y = PRINT_Y + _PRINT_H + 34
    _tracked(d, word, load_font(FONT_DETAIL, 20, index=FONT_DETAIL_BOLD), (*ROSE_GOLD, 255), MAT, y, 6)
    _tracked(d, subtitle, load_font(FONT_DETAIL, 14, index=FONT_DETAIL_MEDIUM), (*WARM_MID, 255), MAT, y + 32, 4)
    if alpha < 1.0:
        layer.putalpha(layer.split()[3].point(lambda a: int(a * alpha)))
    return Image.alpha_composite(canvas_rgba, layer)


def draw_branded_chrome(frame, event_name, org, venue, logo):
    """Program-plate chrome: masthead, footer colophon, and the crossfading placards."""
    c = frame.convert("RGBA")
    d = ImageDraw.Draw(c)

    # Masthead, top-left, shifted down so it isn't jammed at the very edge.
    d.text((MAT, MASTHEAD_Y), event_name, font=load_font(FONT_SCRIPT, 74), fill=TEXT_DARK)
    lines = detail_lines(event_name, org, venue)
    if lines:
        _tracked(d, lines[0].upper(),
                 load_font(FONT_DETAIL, 19, index=FONT_DETAIL_LIGHT), WARM_MID, MAT, VENUE_Y, 5)
    d.line([(MAT, RULE_Y), (CANVAS_W - MAT, RULE_Y)], fill=ROSE_GOLD, width=1)

    # Footer colophon closing the bottom.
    d.line([(MAT, FOOTER_RULE_Y), (CANVAS_W - MAT, FOOTER_RULE_Y)], fill=ROSE_GOLD, width=1)
    if logo:
        c.alpha_composite(logo, ((CANVAS_W - logo.width) // 2, FOOTER_RULE_Y + 40))

    c = _draw_placard(c, BEFORE_STATE, BEFORE_ALPHA)
    c = _draw_placard(c, AFTER_STATE, AFTER_ALPHA)
    return c.convert("RGB")


def draw_label(frame, text, x, y, font, alpha=255):
    """Hold-on-edit / closing: pin the caption to full AFTER. The chrome draws it."""
    set_caption_state(1.0)
    return frame


def ease_in_out(t):
    return t * t * (3 - 2 * t)


def generate_split_frame(
    raw_canvas: Image.Image,
    edit_canvas: Image.Image,
    split_progress: float,
    font: ImageFont.FreeTypeFont,
) -> Image.Image:
    """One frame of the split: the edit is revealed from the centre of the PRINT
    outward. The wipe and its divider live only inside the print rectangle; the
    surrounding cream mat is identical in both canvases, so nothing moves there.
    The BEFORE/AFTER caption is a crossfading placard the chrome draws, not a label
    here, so set its state from the wipe position.

    split_progress: 0.0 = full RAW, 1.0 = full edit.
    """
    set_caption_state(split_progress)
    if split_progress >= 1.0:
        return edit_canvas.copy()

    center = CANVAS_W // 2
    half_gap = int(center * split_progress)
    frame = raw_canvas.copy()

    if half_gap > 0:
        a, b = center - half_gap, center + half_gap
        if b > a:
            frame.paste(edit_canvas.crop((a, 0, b, CANVAS_H)), (a, 0))
        draw = ImageDraw.Draw(frame)
        for x in (a, b):
            if MAT < x < CANVAS_W - MAT:  # only where there is a print to divide
                draw.line([(x, PRINT_Y), (x, PRINT_Y + _PRINT_H)],
                          fill=DIVIDER_COLOR, width=DIVIDER_WIDTH)

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
    # Passed through to generate_split_frame/draw_label for signature compatibility;
    # the caption is now the chrome's placard, so the font itself is unused there.
    font = load_font(FONT_DETAIL, 20, index=FONT_DETAIL_BOLD)

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
                # Hold on full edit; pin the caption to AFTER (chrome draws it).
                frame = edit_z.copy()
                set_caption_state(1.0)

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
            # Fit the audio to the reel length: short tracks loop with
            # crossfaded seams (no jarring restart) instead of cutting the reel
            # short via -shortest. Fall back to the raw track if the fit fails.
            from .audio_fit import fit_audio_to_duration, fallback_audio_opts
            fade = f"afade=t=out:st={TOTAL_DURATION - AUDIO_FADE_DURATION}:d={AUDIO_FADE_DURATION}"
            try:
                audio_in = fit_audio_to_duration(
                    audio_path, str(tmpdir / "audio_fit.wav"), duration=TOTAL_DURATION,
                )
                audio_opts = ["-af", fade]
            except Exception as e:
                print(f"[generate_reel_morph] audio fit failed, using raw track: {e}",
                      file=sys.stderr)
                audio_in = audio_path
                # Padded and capped, never -shortest: a track shorter than the
                # reel used to cut the video to the music (#117).
                audio_opts = fallback_audio_opts(
                    duration=TOTAL_DURATION, fade_duration=AUDIO_FADE_DURATION)
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
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac",
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
