"""
PostRoll — Screen Recording Speed Edit Reel Generator

Creates a 1080x1920 vertical reel from a Lightroom screen recording.
Speeds up the recording to fit target duration, adds before/after closing
frame and audio.

The recording is placed on a blurred background from the edit photo,
cropped vertically to fill the frame as much as possible.

Usage:
    python generate_reel_screen.py \
        --recording screen.mov --raw photo_raw.jpg --edit photo_edit.jpg \
        --audio music.m4a --output output/reel.mp4
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

from .audio_fit import fit_audio_to_duration

from .design_tokens import (
    CREAM,
    FONT_DETAIL,
    FONT_DETAIL_LIGHT,
    FONT_SCRIPT,
    # ROSE_GOLD is read by the chrome tests through this module's
    # namespace rather than by the template itself, so the linter
    # cannot see the use.
    ROSE_GOLD,  # noqa: F401
    TEXT_DARK,
)
from .brand_text import detail_lines


# === Layout, specific to this template ===

CANVAS_W = 1080
CANVAS_H = 1920
FPS = 30

# Timing
CLOSING_FRAME_DURATION = 5.0
TRANSITION_DURATION = 0.7
TARGET_EDIT_DURATION = 20.0

# Branded chrome
CREAM_OPACITY = 210
HEADER_H = 340  # tall enough to push title clear of the iPhone notch / Dynamic Island
TITLE_TOP_Y = 170  # clears notch (~120px) + Dynamic Island with breathing room
FOOTER_H = 100
LOGO_WIDTH = 200

# Audio
AUDIO_FADE_DURATION = 2.0


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except (OSError, IOError):
        return ImageFont.load_default()


def get_video_duration(path: str) -> float:
    """Video duration in seconds, or a refusal naming the file.

    A screen recording that cannot be probed has no length to build a reel
    around, so this refuses rather than guessing one. The message names the
    file, because the old ValueError named the float conversion and left the
    unreadable video out of it entirely (#123).
    """
    seconds = probe_duration(path)
    if seconds is None:
        raise RuntimeError(
            f"Could not read the length of {Path(path).name}. The file may be "
            "truncated, still copying, or in a format ffprobe cannot open. "
            "Check it plays, then retry."
        )
    return seconds


def build_background() -> Image.Image:
    """Flat brand-cream background behind the recording (gallery style)."""
    return Image.new("RGB", (CANVAS_W, CANVAS_H), CREAM)


def build_chrome_overlay(event_name: str, org: str, venue: str,
                         logo_path: str | None) -> Image.Image:
    """Transparent cream header/footer overlay composited over the recording.

    Extracted from the inline build so it is testable and consistent with the
    other reels' draw_branded_chrome. No rule lines (gallery style); detail text
    in Light, not Thin.
    """
    chrome = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))

    header = Image.new("RGBA", (CANVAS_W, HEADER_H), (*CREAM, CREAM_OPACITY))
    chrome.paste(header, (0, 0), header)
    draw = ImageDraw.Draw(chrome)

    title_font = load_font(FONT_SCRIPT, 70)
    detail_font = load_font(FONT_DETAIL, 26, index=FONT_DETAIL_LIGHT)
    bbox = draw.textbbox((0, 0), event_name, font=title_font)
    tw = bbox[2] - bbox[0]
    draw.text(((CANVAS_W - tw) // 2, TITLE_TOP_Y), event_name, font=title_font, fill=TEXT_DARK)

    title_h = bbox[3] - bbox[1]
    info_y = TITLE_TOP_Y + title_h + 20
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
    footer = Image.new("RGBA", (CANVAS_W, FOOTER_H), (*CREAM, CREAM_OPACITY))
    chrome.paste(footer, (0, footer_y), footer)

    if logo_path and Path(logo_path).exists():
        logo = Image.open(logo_path).convert("RGBA")
        logo_scale = LOGO_WIDTH / logo.width
        logo = logo.resize(
            (int(logo.width * logo_scale), int(logo.height * logo_scale)),
            Image.LANCZOS,
        )
        lx = (CANVAS_W - logo.width) // 2
        ly = footer_y + (FOOTER_H - logo.height) // 2
        chrome.paste(logo, (lx, ly), logo)

    return chrome


from postroll.media.probe import probe_duration  # noqa: E402
from postroll.media.audio_fit import fallback_audio_opts  # noqa: E402
from postroll.ai.audio_tags import TUESDAY_DEFAULT_TAGS as _DEFAULT_AUDIO_TAGS  # noqa: E402


def _fit_reel_audio(audio_path, tmpdir_path, duration):
    """Fit `audio_path` to `duration`, looping short tracks with crossfaded
    seams. Returns (audio_input_path, extra_ffmpeg_opts).

    On failure the raw track is padded with silence and the output capped at
    the video length, never `-shortest`: that ended the output when the shorter
    input ended, so a short track cut the video to the length of the music
    (#117)."""
    fade = f"afade=t=out:st={duration - AUDIO_FADE_DURATION}:d={AUDIO_FADE_DURATION}"
    try:
        fitted = fit_audio_to_duration(
            audio_path, str(tmpdir_path / "audio_fit.wav"), duration=duration)
        return fitted, ["-af", fade]
    except Exception as e:
        print(f"[generate_reel_screen] audio fit failed, using raw track: {e}",
              file=sys.stderr)
        return audio_path, fallback_audio_opts(
            duration=duration, fade_duration=AUDIO_FADE_DURATION)


def generate_reel_screen(
    recording_path: str,
    raw_path: str,
    edit_path: str,
    audio_path: str | None,   # None = auto-fetch from Jamendo
    output_path: str,
    event_name: str = "",
    org: str = "",
    venue: str = "",
    closing_frame_path: str | None = None,
    logo_path: str | None = None,
    target_duration: float = TARGET_EDIT_DURATION,
) -> str:
    """Generate a speed edit reel from a screen recording.

    The recording is sped up to fit within target_duration, placed on a
    branded canvas, then a closing before/after frame is appended.
    """
    if audio_path is None:
        from postroll.audio import fetch_audio
        audio_path = fetch_audio(_DEFAULT_AUDIO_TAGS)

    # Get recording duration and calculate speed multiplier
    rec_duration = get_video_duration(recording_path)
    speed_multiplier = rec_duration / target_duration
    total_duration = target_duration + TRANSITION_DURATION + CLOSING_FRAME_DURATION

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir_path = Path(tmpdir)

        # Step 1: Speed up the recording and scale to fit canvas
        # Place the Lightroom window on a blurred background
        # First, figure out recording dimensions
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "stream=width,height",
             "-of", "csv=p=0", recording_path],
            capture_output=True, text=True,
        )
        dims = result.stdout.strip().split(",")
        rec_w, rec_h = int(dims[0]), int(dims[1])

        # Calculate how to fit the recording in the canvas area
        # Leave room for header and footer
        avail_h = CANVAS_H - HEADER_H - FOOTER_H
        avail_w = CANVAS_W

        rec_ratio = rec_w / rec_h
        avail_ratio = avail_w / avail_h

        if rec_ratio > avail_ratio:
            # Recording is wider — fit to width
            scale_w = avail_w
            scale_h = int(avail_w / rec_ratio)
        else:
            # Recording is taller — fit to height
            scale_h = avail_h
            scale_w = int(avail_h * rec_ratio)

        # Make dimensions even (required by h264)
        scale_w = scale_w - (scale_w % 2)
        scale_h = scale_h - (scale_h % 2)

        # Step 2: Flat cream background (gallery style) behind the recording
        bg_path = str(tmpdir_path / "bg.png")
        build_background().save(bg_path)

        # Step 3: Create branded chrome overlay (header + footer)
        chrome = build_chrome_overlay(event_name, org, venue, logo_path)
        chrome_path = str(tmpdir_path / "chrome.png")
        chrome.save(chrome_path)

        # Step 4: Generate closing frame sequence if provided
        closing_path = None
        if closing_frame_path and Path(closing_frame_path).exists():
            closing_path = closing_frame_path

        # Step 5: Use ffmpeg to compose everything
        # Position recording centered in available area (between header and footer)
        rec_x = (CANVAS_W - scale_w) // 2
        rec_y = HEADER_H + (avail_h - scale_h) // 2

        sped_up = str(tmpdir_path / "sped_up.mp4")

        # Two-pass approach for smooth timelapse:
        # Pass 1: Convert VFR recording to CFR and count frames
        cfr_path = str(tmpdir_path / "cfr.mp4")
        cfr_cmd = [
            "ffmpeg", "-y",
            "-i", recording_path,
            "-an", "-r", "30",  # force 30fps constant
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-preset", "ultrafast",
            cfr_path,
        ]
        result = subprocess.run(cfr_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"CFR convert failed: {result.stderr[-500:]}")

        # Get actual CFR frame count
        count_result = subprocess.run(
            ["ffprobe", "-v", "error", "-count_frames",
             "-show_entries", "stream=nb_read_frames",
             "-of", "csv=p=0", cfr_path],
            capture_output=True, text=True, timeout=120,
        )
        try:
            total_src_frames = int(count_result.stdout.strip())
        except ValueError:
            total_src_frames = int(rec_duration * 30)

        # Pass 2: Sample every Nth frame for smooth timelapse
        total_out_frames = int(target_duration * FPS)
        select_n = max(1, total_src_frames // total_out_frames)

        speed_cmd = [
            "ffmpeg", "-y",
            "-i", cfr_path,
            "-vf", f"select=not(mod(n\\,{select_n})),setpts=N/{FPS}/TB,scale={scale_w}:{scale_h}",
            "-an",
            "-frames:v", str(total_out_frames),
            "-r", str(FPS),
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            sped_up,
        ]
        result = subprocess.run(speed_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"Speed up failed: {result.stderr[-500:]}")

        # Compose: bg + sped_up recording overlay + chrome overlay
        composed = str(tmpdir_path / "composed.mp4")
        compose_cmd = [
            "ffmpeg", "-y",
            "-i", bg_path,                 # background image
            "-i", sped_up,                 # sped up recording
            "-i", chrome_path,             # chrome overlay
            "-filter_complex",
            f"[0]loop=loop=-1:size=1:start=0,scale={CANVAS_W}:{CANVAS_H},setpts=N/{FPS}/TB[bg];"
            f"[bg][1]overlay={rec_x}:{rec_y}:shortest=1[with_rec];"
            f"[with_rec][2]overlay=0:0[out]",
            "-map", "[out]",
            "-t", str(target_duration),
            "-r", str(FPS),
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            composed,
        ]
        result = subprocess.run(compose_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"Compose failed: {result.stderr[-500:]}")

        # Step 6: Add closing frame with crossfade transition
        # Encode to a temp name and rename into place atomically so a
        # cancelled render's orphaned ffmpeg can never corrupt the final file.
        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)
        encode_tmp = output.with_suffix(f".{os.getpid()}.tmp.mp4")

        if closing_path:
            # Create closing frame video
            closing_vid = str(tmpdir_path / "closing.mp4")
            closing_cmd = [
                "ffmpeg", "-y",
                "-loop", "1",
                "-i", closing_path,
                "-t", str(CLOSING_FRAME_DURATION + TRANSITION_DURATION),
                "-r", str(FPS),
                "-vf", f"scale={CANVAS_W}:{CANVAS_H}",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                closing_vid,
            ]
            result = subprocess.run(closing_cmd, capture_output=True, text=True)
            if result.returncode != 0:
                raise RuntimeError(f"Closing frame failed: {result.stderr[-500:]}")

            # Get actual composed duration. ffmpeg exited 0 above, but a
            # graph can exit 0 and still write a file ffprobe cannot read, so
            # this is checked rather than assumed (#123).
            composed_dur = probe_duration(composed)
            if composed_dur is None:
                raise RuntimeError(
                    "The composed reel could not be read back after encoding, "
                    "so its length is unknown and the closing hold cannot be "
                    "timed. This usually means the encode produced a bad file."
                )

            # Hold the last frame for 2 seconds so viewer sees the finished edit
            held = str(tmpdir_path / "held.mp4")
            hold_dur = 1.0
            hold_cmd = [
                "ffmpeg", "-y", "-i", composed,
                "-vf", f"tpad=stop_mode=clone:stop_duration={hold_dur}",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                held,
            ]
            result = subprocess.run(hold_cmd, capture_output=True, text=True)
            if result.returncode != 0:
                raise RuntimeError(f"Hold last frame failed: {result.stderr[-500:]}")

            held_dur = composed_dur + hold_dur
            actual_total = held_dur + CLOSING_FRAME_DURATION

            # Fade out held timelapse, fade in closing frame, then concat
            faded_tl = str(tmpdir_path / "faded_tl.mp4")
            fade_tl_cmd = [
                "ffmpeg", "-y", "-i", held,
                "-vf", f"fade=t=out:st={held_dur - 0.5}:d=0.5",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                faded_tl,
            ]
            result = subprocess.run(fade_tl_cmd, capture_output=True, text=True)
            if result.returncode != 0:
                raise RuntimeError(f"Fade timelapse failed: {result.stderr[-500:]}")

            faded_cl = str(tmpdir_path / "faded_cl.mp4")
            fade_cl_cmd = [
                "ffmpeg", "-y", "-i", closing_vid,
                "-vf", "fade=t=in:st=0:d=0.5",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                faded_cl,
            ]
            result = subprocess.run(fade_cl_cmd, capture_output=True, text=True)
            if result.returncode != 0:
                raise RuntimeError(f"Fade closing failed: {result.stderr[-500:]}")

            # Concat + add audio
            concat_list = str(tmpdir_path / "concat.txt")
            with open(concat_list, "w") as f:
                f.write(f"file '{faded_tl}'\nfile '{faded_cl}'\n")

            audio_in, audio_opts = _fit_reel_audio(
                audio_path, tmpdir_path, actual_total)
            final_cmd = [
                "ffmpeg", "-y",
                "-f", "concat", "-safe", "0", "-i", concat_list,
                "-i", audio_in,
                # Explicit stream selection so MP3 cover art can never be
                # picked as the video stream.
                "-map", "0:v:0", "-map", "1:a:0",
                # Cap the container at the video length. Without -t, ffmpeg
                # encodes until the longest stream (the full music track)
                # ends, leaving minutes of dead air after the video.
                "-t", str(actual_total),
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                *audio_opts,
                str(encode_tmp),
            ]
        else:
            # Just add audio
            audio_in, audio_opts = _fit_reel_audio(
                audio_path, tmpdir_path, target_duration)
            final_cmd = [
                "ffmpeg", "-y",
                "-i", composed,
                "-i", audio_in,
                "-map", "0:v:0", "-map", "1:a:0",
                "-t", str(target_duration),
                *audio_opts,
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                str(encode_tmp),
            ]

        result = subprocess.run(final_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            encode_tmp.unlink(missing_ok=True)
            raise RuntimeError(f"Final encode failed: {result.stderr[-500:]}")
        os.replace(encode_tmp, output)

    print(f"Screen recording reel generated: {output} "
          f"({total_duration:.1f}s, {speed_multiplier:.1f}x speed)")
    return str(output)


def main():
    parser = argparse.ArgumentParser(description="Generate a speed edit reel")
    parser.add_argument("--recording", required=True, help="Path to screen recording")
    parser.add_argument("--raw", required=True, help="Path to RAW photo")
    parser.add_argument("--edit", required=True, help="Path to edited photo")
    parser.add_argument("--audio", default=None, help="Path to audio file (omit to auto-fetch from Jamendo)")
    parser.add_argument("--event", default="")
    parser.add_argument("--org", default="")
    parser.add_argument("--venue", default="")
    parser.add_argument("--closing-frame", default=None)
    parser.add_argument("--logo", default=None)
    parser.add_argument("--target-duration", type=float, default=TARGET_EDIT_DURATION)
    parser.add_argument("--output", default="output/reel_screen.mp4")
    args = parser.parse_args()

    generate_reel_screen(
        recording_path=args.recording,
        raw_path=args.raw,
        edit_path=args.edit,
        audio_path=args.audio,
        output_path=args.output,
        event_name=args.event,
        org=args.org,
        venue=args.venue,
        closing_frame_path=args.closing_frame,
        logo_path=args.logo,
        target_duration=args.target_duration,
    )


if __name__ == "__main__":
    main()
