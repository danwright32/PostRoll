"""PostRoll: the 3-photo Tuesday reel (#164).

A Tuesday reel on the program plate: masthead over a rose-gold rule, the
photograph hung as a matted print, a caption placard below it, a footer
colophon. One full-size print moves through three states, RAW, then the colour
edit, then the B&W, revealed by a divider sweeping across the print.

The sweep is what distinguishes this from the standard Tuesday reel, which opens
its print from the centre outward. The FIRST reveal wipes left to right and the
SECOND wipes back, so the divider exits the right edge and returns from it: one
gesture returning rather than the same move performed twice, and the B&W settles
symmetrically to how the RAW started. Because the colour and the B&W are the same
photograph, that second sweep reads as colour draining out of the picture.

Reached only when Dan supplies a B&W after. `resolve_tuesday_reel_style` routes
here on exactly that, and the style override that was the other way in has no
writer anywhere in the app (#324), so a B&W is required rather than optional: a
two-photo reel through here would be a shape the product cannot produce, running
a timeline built for two sweeps.

Usage:
    python generate_reel_slider.py \
        --raw photo_raw.jpg --edit photo_edit.jpg --bw photo_bw.jpg \
        --audio music.m4a --output output/reel.mp4
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

from .design_tokens import DIVIDER_WHITE as DIVIDER_COLOR
from .generate_collage import crop_to_fill
from .program_plate import (  # noqa: F401  (re-exported for callers and bands)
    CANVAS_W,
    CANVAS_H,
    MAT,
    PRINT_W,
    MASTHEAD_Y,
    VENUE_Y,
    RULE_Y,
    PRINT_Y,
    FOOTER_RULE_Y,
    LOGO_WIDTH,
    PLACARD_TOP_GAP,
    PLACARD_BLOCK_H,
    print_rect,
    hang_print,
    draw_plate_chrome,
    placard_alphas,
    load_logo,
)


FPS = 30

# Timing, settled with Dan on an encoded prototype. A third state needs a second
# sweep; each shortens from the 5.0 the two-state reels use so both reveals have
# room without the reel growing by half.
HOLD_RAW = 1.5
SWEEP_DURATION = 3.5
HOLD_COLOUR = 1.2
HOLD_BW = 1.5
TRANSITION_DURATION = 1.5   # crossfade to the closing frame
CLOSING_FRAME_DURATION = 3.0

#: When the reel begins dissolving into the closing graphic, in seconds. Named
#: for the same reason as the morph's (#335): the window has to be addressable
#: to be checked, and this reel dissolves from a plate holding one print into a
#: graphic holding three.
CLOSING_CROSSFADE_START = (HOLD_RAW + SWEEP_DURATION + HOLD_COLOUR
                           + SWEEP_DURATION + HOLD_BW)

TOTAL_DURATION = (CLOSING_CROSSFADE_START + TRANSITION_DURATION
                  + CLOSING_FRAME_DURATION)

DIVIDER_WIDTH = 4

#: The three states, in the order the reel moves through them. The wording map
#: lives with the closing frame's, so a caption here can never drift from it.
STATES = ("RAW", "Edit", "B&W")

AUDIO_FADE_DURATION = 2.0

#: Only for the tests that need a real wordmark; the app passes its own.
DEFAULT_LOGO_FOR_TESTS = (
    Path(__file__).resolve().parent.parent / "assets" / "logo-black.png")


def ease_in_out(t: float) -> float:
    """Dramatic ease: slow start, fast middle, slow end."""
    if t < 0.3:
        return (t / 0.3) ** 2 * 0.15
    if t < 0.7:
        return 0.15 + ((t - 0.3) / 0.4) * 0.7
    return 0.85 + (1 - (1 - (t - 0.7) / 0.3) ** 2) * 0.15


def divider_x(rect: tuple[int, int, int, int], progress: float,
              rightward: bool) -> int:
    """Where the divider sits at `progress` through a sweep.

    Travels the PRINT's width, not the canvas's, so the cream mat either side
    never moves. Reversing is what makes the second reveal read as a return:
    `divider_x(rect, 1.0, rightward=True)` and `divider_x(rect, 0.0,
    rightward=False)` are the same edge.
    """
    left, _, width, _ = rect
    progress = max(0.0, min(1.0, progress))
    return int(left + width * (progress if rightward else 1.0 - progress))


def swept(before: Image.Image, after: Image.Image,
          rect: tuple[int, int, int, int], progress: float,
          rightward: bool) -> Image.Image:
    """One frame of a reveal: `after` uncovered across the print."""
    left, top, width, height = rect
    frame = before.copy()
    x = divider_x(rect, progress, rightward)

    if rightward:
        box = (left, top, x, top + height)
    else:
        box = (x, top, left + width, top + height)
    if box[2] > box[0]:
        frame.paste(after.crop(box), (box[0], box[1]))

    if left < x < left + width:
        ImageDraw.Draw(frame).line(
            [(x, top), (x, top + height)], fill=DIVIDER_COLOR, width=DIVIDER_WIDTH)
    return frame


def hang_the_states(raw: Image.Image, edit: Image.Image,
                    bw: Image.Image) -> tuple[tuple[int, int, int, int], list[Image.Image]]:
    """The three canvases, all hung in ONE rectangle.

    The rectangle comes from the EDIT: it is the photograph the reel is about,
    and the caption hangs off the print the viewer ends on. A photo of another
    shape is cropped to fill through the shared `crop_to_fill`, top-anchored
    (#167), rather than squashed: distorting a face is worse than losing an
    edge, and a second crop written here would sit outside the parity fixture
    the collage and the app already agree through.
    """
    rect = print_rect(edit.size)
    _, _, width, height = rect
    canvases = [
        hang_print(crop_to_fill(photo.convert("RGB"), width, height), rect)
        for photo in (raw, edit, bw)
    ]
    return rect, canvases


from postroll.ai.audio_tags import TUESDAY_DEFAULT_TAGS as _DEFAULT_AUDIO_TAGS  # noqa: E402
from .missing_media import require_present  # noqa: E402


def draw_branded_chrome(frame, event_name: str, org: str, venue: str, logo,
                        rect: tuple[int, int, int, int],
                        outgoing: str, incoming: str, progress: float):
    """Program-plate chrome: masthead, footer colophon, crossfading placards.

    Module level rather than a closure inside the render, so a check can draw
    one frame of this template's chrome without encoding a reel (#759). The
    render calls it too, so what is measured is what ships rather than a second
    copy of the same call written beside it (L107).

    Named to match `generate_reel_morph.draw_branded_chrome`, which is the same
    idea for the other plate reel, so a check that wants both can ask both the
    same question.
    """
    before_alpha, after_alpha = placard_alphas(progress)
    return draw_plate_chrome(
        frame, event_name, org, venue, logo, rect,
        [(outgoing, before_alpha), (incoming, after_alpha)])


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
    """Render the 3-photo Tuesday reel.

    `bw_path` is required despite its keyword default, so that omitting it fails
    loudly rather than silently rendering a two-photo reel on a timeline built
    for three states.
    """
    # A photo that was chosen but is not on disk is reported, never quietly
    # dropped: falling back produced a plausible file that was not the one asked
    # for, so there was nothing to notice (#180).
    raw_path = require_present(raw_path, "RAW photo")
    edit_path = require_present(edit_path, "edited photo")
    if not bw_path:
        raise ValueError(
            "The 3-photo Tuesday reel needs a black and white after. Nothing in "
            "the app reaches this reel without one, so rendering it as a two "
            "photo reveal would produce a file the product cannot otherwise "
            "make, on a timeline built for two sweeps. Use the program-plate "
            "morph reel for two photos.")
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

    rect, canvases = hang_the_states(
        Image.open(raw_path), Image.open(edit_path), Image.open(bw_path))

    closing_frame = None
    if closing_frame_path and Path(closing_frame_path).exists():
        closing_frame = Image.open(closing_frame_path).convert("RGB").resize(
            (CANVAS_W, CANVAS_H), Image.LANCZOS)

    logo = load_logo(logo_path)

    def chrome(frame, outgoing: str, incoming: str, progress: float):
        return draw_branded_chrome(frame, event_name, org, venue, logo, rect,
                                   outgoing, incoming, progress)

    marks = [int(s * FPS) for s in
             (HOLD_RAW, SWEEP_DURATION, HOLD_COLOUR, SWEEP_DURATION, HOLD_BW,
              TRANSITION_DURATION, CLOSING_FRAME_DURATION)]

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        index = 0

        def write(frame):
            nonlocal index
            frame.save(str(tmpdir / f"frame_{index:05d}.png"), "PNG")
            index += 1

        # Hold on the RAW.
        for _ in range(marks[0]):
            write(chrome(swept(canvases[0], canvases[1], rect, 0.0, True),
                         STATES[0], STATES[1], 0.0))

        # Sweep left to right, uncovering the colour edit.
        for step in range(marks[1]):
            p = ease_in_out(step / marks[1])
            write(chrome(swept(canvases[0], canvases[1], rect, p, True),
                         STATES[0], STATES[1], p))

        # Hold on the colour edit.
        for _ in range(marks[2]):
            write(chrome(swept(canvases[1], canvases[2], rect, 0.0, False),
                         STATES[1], STATES[2], 0.0))

        # Sweep back, right to left, uncovering the B&W.
        for step in range(marks[3]):
            p = ease_in_out(step / marks[3])
            write(chrome(swept(canvases[1], canvases[2], rect, p, False),
                         STATES[1], STATES[2], p))

        # Hold on the B&W.
        settled = chrome(swept(canvases[1], canvases[2], rect, 1.0, False),
                         STATES[1], STATES[2], 1.0)
        for _ in range(marks[4]):
            write(settled)

        # Crossfade to the closing frame, keeping the plate on the outgoing
        # frame: dropping it produced a visible flash of unbranded photo.
        for step in range(marks[5]):
            if closing_frame:
                write(Image.blend(settled, closing_frame,
                                  ease_in_out(step / marks[5])))
            else:
                write(settled)

        # Hold the closing frame.
        for _ in range(marks[6]):
            write(closing_frame.copy() if closing_frame else settled)

        # Encode to a temp name and rename into place atomically so a cancelled
        # render's orphaned ffmpeg can never corrupt the final file.
        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)
        encode_tmp = output.with_suffix(f".{os.getpid()}.tmp.mp4")

        if audio_path:
            # Fit the audio to the reel length: short tracks loop with
            # crossfaded seams instead of cutting the reel short via -shortest.
            from .audio_fit import fit_audio_to_duration, fallback_audio_opts
            fade = (f"afade=t=out:st={TOTAL_DURATION - AUDIO_FADE_DURATION}"
                    f":d={AUDIO_FADE_DURATION}")
            try:
                audio_in = fit_audio_to_duration(
                    audio_path, str(tmpdir / "audio_fit.wav"),
                    duration=TOTAL_DURATION)
                audio_opts = ["-af", fade]
            except Exception as e:
                print(f"[generate_reel_slider] audio fit failed, using raw track: {e}",
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

    print(f"Three photo Tuesday reel generated: {output} "
          f"({TOTAL_DURATION}s, {FPS}fps)")
    return str(output)


def main():
    parser = argparse.ArgumentParser(
        description="Generate the 3-photo Tuesday reel")
    parser.add_argument("--raw", required=True, help="Path to RAW photo")
    parser.add_argument("--edit", required=True, help="Path to edited photo")
    parser.add_argument("--bw", required=True, help="Path to the B&W after")
    parser.add_argument("--audio", default=None,
                        help="Path to audio file (omit to auto-fetch from Jamendo)")
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
