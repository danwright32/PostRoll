"""
PostRoll: Friday clip reel Phase 3, animated title-card overlay.

Renders the event name as a transparent PNG using the same script font and
drop-shadow technique already proven on the story template
(generate_story.py's FONT_SCRIPT + _fit_script_title), then composites it
onto the reel's opening seconds via ffmpeg's fade + overlay filters: a
short fade in, a hold, a fade out. No AI involved, purely deterministic
graphics and video compositing. A new visual treatment, positioned in the
upper third rather than bottom-anchored to a photo, not a reuse of
cover.png.

Usage:
    from postroll.media.generate_title_card import apply_title_card

    apply_title_card(reel_path, event_name, out_path)
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

from .generate_story import (
    CANVAS_H,
    CANVAS_W,
    ROSE_GOLD_DARK,
    TEXT_WHITE,
    _fit_script_title,
)

# Baseline y of the title's last line: upper third of the canvas, clear of
# whatever's happening in the clip below (Dan's call, 2026-07-09).
TITLE_CARD_ANCHOR_Y = 420

# On-screen timing (Dan's call, 2026-07-09): fades in, holds, fades out,
# ~2s total and early in the reel, so it reads as a reveal, not a banner.
TITLE_CARD_FADE_SECONDS = 0.4
TITLE_CARD_HOLD_SECONDS = 1.2
TITLE_CARD_TOTAL_SECONDS = TITLE_CARD_FADE_SECONDS * 2 + TITLE_CARD_HOLD_SECONDS


class TitleCardError(RuntimeError):
    """Raised when ffmpeg fails to composite the title card."""


def _probe_duration(path: str | Path) -> float:
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True,
    )
    try:
        return float(proc.stdout.strip())
    except ValueError:
        raise TitleCardError(f"could not probe duration of {path}: {proc.stderr.strip()}")


def render_title_card_image(event_name: str, output_path: str | Path) -> str:
    """Render `event_name` as a transparent PNG (CANVAS_W x CANVAS_H)
    using the story template's script font, drop shadow, and inline
    rose-gold rule, positioned in the upper third."""
    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    margin = 60
    max_text_w = CANVAS_W - 2 * margin - 2 * 28
    lines, font = _fit_script_title(event_name, canvas, max_text_w)

    tmp_draw = ImageDraw.Draw(canvas)
    line_metrics: list[tuple[int, int]] = []
    text_h_single = 0
    for line in lines:
        bbox = tmp_draw.textbbox((0, 0), line, font=font)
        line_w = bbox[2] - bbox[0]
        text_h_single = max(text_h_single, bbox[3] - bbox[1])
        line_metrics.append(((CANVAS_W - line_w) // 2, line_w))
    line_gap = int(text_h_single * 0.85)

    last_line_y = TITLE_CARD_ANCHOR_Y - text_h_single
    first_line_y = last_line_y - (len(lines) - 1) * line_gap

    # Soft drop shadow, same recipe as the story template's title.
    shadow = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    for i, (line, (lx, _)) in enumerate(zip(lines, line_metrics)):
        ly = first_line_y + i * line_gap
        sd.text((lx + 2, ly + 3), line, font=font, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=8))
    canvas = Image.alpha_composite(canvas, shadow)

    # Inline rose-gold rules flanking the last line, same editorial motif
    # as the story template.
    last_x, last_w = line_metrics[-1]
    line_y = last_line_y + int(text_h_single * 0.52)
    gap = 28
    rule_layer = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rule_layer)
    rd.line([(margin, line_y), (last_x - gap, line_y)], fill=(*ROSE_GOLD_DARK, 170), width=1)
    rd.line([(last_x + last_w + gap, line_y), (CANVAS_W - margin, line_y)], fill=(*ROSE_GOLD_DARK, 170), width=1)
    canvas = Image.alpha_composite(canvas, rule_layer)

    draw = ImageDraw.Draw(canvas)
    for i, (line, (lx, _)) in enumerate(zip(lines, line_metrics)):
        ly = first_line_y + i * line_gap
        draw.text((lx, ly), line, font=font, fill=TEXT_WHITE)

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(str(output), "PNG")
    return str(output)


def apply_title_card(
    video_path: str | Path,
    event_name: str,
    output_path: str | Path,
    *,
    tmp_dir: str | Path | None = None,
) -> str:
    """Composite `event_name`'s title card onto `video_path`'s opening
    seconds (fade in, hold, fade out), writing the result to
    `output_path`. Raises TitleCardError if ffmpeg fails."""
    def _run(tmp: str) -> str:
        tmp_path = Path(tmp)
        overlay_png = tmp_path / "title_card.png"
        render_title_card_image(event_name, overlay_png)

        source_duration = _probe_duration(video_path)

        fade_out_start = TITLE_CARD_FADE_SECONDS + TITLE_CARD_HOLD_SECONDS
        out = Path(output_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", str(video_path),
            # -loop 1: without it ffmpeg's png demuxer reads the overlay as
            # a single frame, not a continuous stream, so the title would
            # only ever composite onto the very first output frame (real
            # bug found 2026-07-09: every frame after the first came back
            # byte-identical to the un-composited source).
            #
            # -t <source_duration>: without an explicit bound, a looped
            # image input is infinite, and this ffmpeg build doesn't
            # reliably stop the encode at the main video's EOF on its own
            # (real bug found 2026-07-09: the encode never terminated,
            # spinning at 900%+ CPU indefinitely). Bounding the loop to the
            # source's own duration is always enough, since the overlay is
            # only ever drawn during its early enable() window regardless.
            "-loop", "1", "-t", f"{source_duration:.3f}", "-i", str(overlay_png),
            "-filter_complex",
            f"[1:v]fade=t=in:st=0:d={TITLE_CARD_FADE_SECONDS:.2f}:alpha=1,"
            f"fade=t=out:st={fade_out_start:.2f}:d={TITLE_CARD_FADE_SECONDS:.2f}:alpha=1[titled];"
            f"[0:v][titled]overlay=0:0:enable='lte(t,{TITLE_CARD_TOTAL_SECONDS:.2f})'[vout]",
            "-map", "[vout]", "-map", "0:a?",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            str(out),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 or not out.exists():
            raise TitleCardError(f"ffmpeg title card overlay failed: {result.stderr.strip()}")
        return str(out)

    if tmp_dir is not None:
        Path(tmp_dir).mkdir(parents=True, exist_ok=True)
        return _run(str(tmp_dir))
    with tempfile.TemporaryDirectory(prefix="postroll-titlecard-") as tmp:
        return _run(tmp)
