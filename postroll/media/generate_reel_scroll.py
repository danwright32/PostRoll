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
from functools import lru_cache
from pathlib import Path
from PIL import Image, ImageDraw

# Reuse the collage's pan/zoom-aware crop so per-photo offsets produce
# identical output in both the strip preview PNG and the final encoded reel.
from .generate_collage import DEFAULT_CROP_OFFSET, crop_to_fill as _crop_to_fill

from .design_tokens import (
    # ROSE_GOLD is read by the chrome tests through this module's,
    # cannot see the use.,
    # namespace rather than by the template itself, so the linter,
    CREAM,
    FONT_DETAIL,
    FONT_DETAIL_LIGHT,
    FONT_SCRIPT,
    GUTTER as GAP,
    HAIRLINE,
    MAT_GALLERY as MAT,
    ROSE_GOLD,  # noqa: F401,
    SAFE_TOP,
    TEXT_DARK,
    load_font,
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
# 30, and it was briefly 60 (#. 2026-08-30). Instagram RE-ENCODES every reel to
# 30fps and it DROPS frames rather than blending them, both measured off a reel
# posted and saved back that day: 720x1280, 30fps, 0.70 Mbps, and its frames as
# vertically sharp as our master (ratio 0.99), which a blend could not be.
#
# So a 60fps master reaches nobody. Half its frames are discarded and the
# survivors are the ones we would have rendered anyway, which makes the movement
# a viewer sees identical either way. What 60fps DID change was the preview: it
# looked twice as smooth as the posted reel, and a whole evening of judging
# scroll speed was spent against a file no viewer sees. Rendering at the rate
# that ships is what keeps what is reviewed and what is published the same
# picture (L64).
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
# ── The title band (#752) ─────────────────────────────────────────────────────
#
# The title used to be drawn at y=35 in a cream header that started at the very
# top of the frame, which put the show's name under the phone's status bar and
# Dynamic Island on every reel published. The band clears that band now.
#
# It is real chrome, not a plate: the gallery scrolls in the viewport BELOW it
# (#898). It was laid on the photography until then, and the price of that was
# not a trimmed top row, it was two landscape prints that were never visible at
# any point in the file. What the phone covers above the band is mat.

#: Where the cream band starts: immediately below the band the phone covers.
TITLE_BAND_TOP = SAFE_TOP

#: How tall it is: the padding above the title, the 70pt title at its tallest
#: (76px), the 20px gap, two detail lines at 36px, and room below them.
TITLE_BAND_H = 220

#: Where the photography is clear of the chrome again. What the strip lays its
#: prints below, what the colophon search starts at, and what the tests read.
TITLE_BAND_BOTTOM = TITLE_BAND_TOP + TITLE_BAND_H

#: The same fact under the name the screen reel uses for it, so a check that
#: asks "where does the top chrome end" reads one name across both templates.
CHROME_BOTTOM_Y = TITLE_BAND_BOTTOM

#: Where the title sits inside the band.
TITLE_TOP_Y = TITLE_BAND_TOP + 26
# The bottom chrome. The colophon does not live here (it is baked into the strip
# right under the last photo), so this is a thin band closing the gallery.
FOOTER_H = 100

# ── The viewport (#898) ──────────────────────────────────────────────────────
#
# The window the strip scrolls through. Everything between the two pieces of
# chrome, and nothing outside it: a print placed here cannot be painted over by
# the band or the footer, whatever the shape of the photograph or wherever the
# scroll has reached.
#
# The sibling template is the reference. `generate_reel_screen` has reserved
# `CANVAS_H - HEADER_H - FOOTER_H` and placed its content at `HEADER_H` since it
# was written, so its chrome has never overlapped its photography.

#: The first row of pixels the photography may occupy.
VIEWPORT_TOP = TITLE_BAND_BOTTOM

#: The first row it may not: where the footer starts.
VIEWPORT_BOTTOM = CANVAS_H - FOOTER_H

#: How much of the frame the gallery gets. What the strip is cropped to, and
#: what the scroll range is measured against.
VIEWPORT_H = VIEWPORT_BOTTOM - VIEWPORT_TOP
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


#: How much of the scroll is spent getting up to speed, and the same again
#: slowing down. The rest of it runs at a constant speed.
EASE_RAMP = 0.15


def _smoothstep_area(u: float) -> float:
    """Area under smoothstep from 0 to `u`, both in units of the ramp width."""
    return u ** 3 - u ** 4 / 2


def ease_in_out(t: float) -> float:
    """How far through the strip the scroll has travelled at `t` in [0, 1].

    A trapezoidal speed profile: smoothstep up over the first `EASE_RAMP`,
    constant through the middle, smoothstep down over the last `EASE_RAMP`.
    Smoothstep rather than a straight ramp because its own slope is zero at
    both ends, so the speed is continuous everywhere the three pieces meet.

    It replaced three formulas stitched together whose speed jumped about 8% at
    each seam. Measured in the delivered reel on 2026-08-30: 33px a frame
    either side of t=0.12, dropping instantly to 30, and the mirror of it at
    t=0.88. Two lurches per reel, both visible, and neither of them intended.

    Peak speed is 1/(1 - EASE_RAMP) of the average, which at 0.15 is 1.18. The
    old curve cruised at 1.16, so the reel still moves the way it did: what
    changes is that it gets there without a step.
    """
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0

    a = EASE_RAMP
    total = 1.0 - a  # area under the speed profile, which normalises position
    if t < a:
        return a * _smoothstep_area(t / a) / total
    if t <= 1.0 - a:
        return (a * 0.5 + (t - a)) / total
    return 1.0 - a * _smoothstep_area((1.0 - t) / a) / total


def build_collage_strip(
    photo_paths: list[str],
    seed: int,
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
    if seed is None:
        # Refused rather than defaulted (#1062, L339). `random.Random(None)`
        # seeds from system entropy, so the masonry layout was different on
        # every run: adjusting one crop re-laid-out all 234 photographs, and
        # two renders of identical inputs produced different reels, which is
        # what made proving a render refactor a no-op read as a broken
        # renderer. The app mints and stores a seed on a day's first render,
        # so reaching here without one is a defect upstream, not a caller
        # asking for variety.
        raise ValueError(
            "build_collage_strip needs a layout seed: without one the masonry "
            "is reshuffled on every render and no two runs of the same inputs "
            "produce the same reel")
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
    # One gutter above the first row, the same gutter that sits between every
    # other pair of rows. The strip's top edge is what the viewport opens on, so
    # this is the whole distance between the band and the first print: the dead
    # cream #752 was worried about is what a viewport with a deep top pad would
    # produce, and the answer is not to pad it. It is a gutter rather than zero
    # because the hairline framing each print is drawn one pixel outside it.
    top_pad = ROW_GAP
    # No FOOTER_H reserved here since #898: the viewport ends where the footer
    # starts, so the strip never reaches under it and padding for it would only
    # add mat the scroll has to travel through.
    if logo:
        bottom_pad = COLOPHON_GAP_ABOVE + logo.height + COLOPHON_GAP_BELOW
    else:
        bottom_pad = 30
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


def _draw_chrome_onto(frame_rgba: Image.Image, event_name: str, org: str,
                      venue: str) -> Image.Image:
    """Lay the band, the hairlines, the title and the footer onto an RGBA image.

    Split out of `draw_branded_chrome` so the chrome can be drawn ONCE onto a
    transparent canvas and reused, rather than re-laid-out on every frame of a
    scroll where none of it moves (#. measured 2026-08-30: 6.5ms of a frame,
    8s of a 1230 frame render, for the same pixels 1230 times).

    Both the per-frame path and the cached overlay come through here, so the
    two cannot draw different chrome: a restatement beside the overlay would be
    a second definition that drifts silently (L107).
    """
    band = Image.new("RGBA", (CANVAS_W, TITLE_BAND_H), (*CREAM, 255))
    frame_rgba.paste(band, (0, TITLE_BAND_TOP), band)
    draw = ImageDraw.Draw(frame_rgba)
    # A hairline at each edge, because the band now meets photography rather
    # than the top of the frame and cream against a bright print has nothing to
    # say where one ends and the other begins.
    draw.line([(0, TITLE_BAND_TOP), (CANVAS_W, TITLE_BAND_TOP)],
              fill=HAIRLINE, width=2)
    draw.line([(0, TITLE_BAND_BOTTOM - 1), (CANVAS_W, TITLE_BAND_BOTTOM - 1)],
              fill=HAIRLINE, width=2)

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
    footer = Image.new("RGBA", (CANVAS_W, FOOTER_H), (*CREAM, 255))
    frame_rgba.paste(footer, (0, footer_y), footer)

    return frame_rgba


def draw_branded_chrome(frame: Image.Image, event_name: str, org: str,
                        venue: str) -> Image.Image:
    """Draw the cream title band and the footer mask.

    No wordmark, and no parameter to pass one (#774). It used to take a logo
    and paste it into the footer at `CANVAS_H - FOOTER_H`, which is inside the
    band Instagram lays its account row and caption over (#753). Nothing ever
    passed one, so it never shipped, but a dead parameter whose only effect is
    to put the signature where nobody can read it is a trap rather than an
    option. The reel's colophon is baked into the scrolling strip instead, well
    clear of that band.

    This is the one-shot path, kept because it is what the reference checks and
    the other templates' readings come through. A scroll render uses
    `apply_chrome`, which paints the identical picture from a cached overlay.
    """
    return _draw_chrome_onto(frame.convert("RGBA"), event_name, org,
                             venue).convert("RGB")


@lru_cache(maxsize=4)
def chrome_tiles(event_name: str, org: str, venue: str
                 ) -> tuple[tuple[int, Image.Image], ...]:
    """The chrome, drawn once, as the (top, tile) pastes a frame needs.

    Derived from what `_draw_chrome_onto` actually PAINTS rather than from the
    band and footer constants: the rows are found by reading back which of them
    carry ink, so chrome added somewhere new is carried automatically instead
    of being silently dropped by an optimisation that knew about two bands
    (L96). The 2px hairline straddling `TITLE_BAND_TOP` is why this matters
    already: it paints a row ABOVE the band it belongs to.

    Cached because the arguments are the event's own name, org and venue, which
    do not change within a render.
    """
    overlay = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    _draw_chrome_onto(overlay, event_name, org, venue)

    alpha = overlay.getchannel("A")
    inked = [y for y in range(CANVAS_H)
             if alpha.crop((0, y, CANVAS_W, y + 1)).getbbox() is not None]

    tiles: list[tuple[int, Image.Image]] = []
    for y in inked:
        if tiles and y == tiles[-1][0] + tiles[-1][1]:
            tiles[-1] = (tiles[-1][0], tiles[-1][1] + 1)
        else:
            tiles.append((y, 1))
    return tuple((top, overlay.crop((0, top, CANVAS_W, top + height)))
                 for top, height in tiles)


def apply_chrome(frame: Image.Image, event_name: str, org: str,
                 venue: str) -> Image.Image:
    """`draw_branded_chrome`'s picture, pasted from the cached overlay.

    Asserted pixel for pixel against the drawn version in
    `tests/test_reel_scroll_render_path.py`, so this is a cost change and not a
    design one.
    """
    for top, tile in chrome_tiles(event_name, org, venue):
        frame.paste(tile, (0, top), tile)
    return frame


def max_scroll_for(strip_height: int) -> int:
    """How far the strip travels: the part of it that cannot be shown at once.

    Shared with the checks for the same reason `compose_frame` is: a scroll
    range restated beside a check samples a different journey from the one the
    encoder renders.
    """
    return max(0, strip_height - VIEWPORT_H)


def place_strip(strip: Image.Image, scroll_y: float) -> Image.Image:
    """Where the photography lands in the frame, before any chrome is drawn.

    `scroll_y` is fractional. It used to be truncated to whole pixels by the
    caller, which at a true 30.4px a frame produced an alternating 30, 31 and
    wobbled the speed a few percent on every single frame of the reel.

    Split out from `compose_frame` so a check can ask where the prints ARE
    rather than where they can still be SEEN. The band and the footer mask are
    opaque cream, so a frame read after they are drawn reports nothing under
    them whether they are covering a photograph or the mat, and a check written
    that way cannot fail (L1, L159).
    """
    limit = max_scroll_for(strip.height)
    scroll_y = min(max(float(scroll_y), 0.0), float(limit))
    top = int(scroll_y)
    frac = scroll_y - top

    window = strip.crop((0, top, CANVAS_W, top + VIEWPORT_H))
    if frac and top < limit:
        # The row below, weighted by how far between the two the scroll sits.
        # Clamped rather than padded: cropping past the last row of the strip
        # returns black, which would put a growing black band under the last
        # photograph at exactly the end of the scroll.
        window = Image.blend(
            window, strip.crop((0, top + 1, CANVAS_W, top + 1 + VIEWPORT_H)), frac)

    frame = Image.new("RGB", (CANVAS_W, CANVAS_H), CREAM)
    frame.paste(window, (0, VIEWPORT_TOP))
    return frame


def compose_frame(strip: Image.Image, scroll_y: float, event_name: str,
                  org: str, venue: str) -> Image.Image:
    """One frame of the reel: the strip at `scroll_y`, with the chrome over it.

    The encoder and the checks that measure a frame both come through here, so
    what is measured is what ships. Reading the composition off the encoder's
    loop meant a check re-stating the crop beside it, which is a second
    definition of the frame that drifts silently (L107).

    Motion blur was built here and taken back out on 2026-08-30. It made the
    scroll marginally smoother and the photographs visibly softer, and at 60fps
    the jumps it was written to hide are already small enough to fuse. Judged
    by watching a matched pair of the reported reel side by side, at 130.7s
    against 38.4s to render. It is in the history if the trade ever changes.
    """
    return apply_chrome(place_strip(strip, scroll_y), event_name, org, venue)



def scroll_frames(strip: Image.Image, *, event_name: str, org: str, venue: str,
                  scroll_duration: float, fps: int | None = None,
                  closing_frame: Image.Image | None = None):
    """Every frame of the reel, in order, as an iterator.

    The loop used to live inside `generate_reel_scroll` between the strip and
    ffmpeg, which meant the only way for a check to read a frame was to glob
    the temp PNGs while the encoder held them. There are no temp PNGs now, and
    a check that wants to know what a frame SHOWS should not have to run an
    encode to find out. So the frames are a generator: the encoder consumes it
    and so can a test, and both see the same pictures.

    Yielded lazily on purpose. A 60fps reel is thousands of 6 MB frames and
    materialising them would cost more memory than the strip.

    `fps` is resolved from the module at call time rather than defaulted in the
    signature, so a test that lowers `FPS` to keep a fixture quick actually
    lowers it (a default bound at import would freeze the shipping value).
    """
    fps = FPS if fps is None else fps
    total_duration = scroll_duration + HOLD_END + CLOSING_FRAME_DURATION
    total_frames = int(total_duration * fps)
    n_scroll = int(scroll_duration * fps)
    n_hold = int(HOLD_END * fps)
    max_scroll = max_scroll_for(strip.height)

    def at(i: int) -> float:
        """Where the strip sits on scroll frame `i`. Fractional: truncating it
        to whole pixels is what used to wobble the speed frame to frame."""
        return ease_in_out(min(i, n_scroll) / n_scroll) * max_scroll

    def framed(scroll_y: float) -> Image.Image:
        return compose_frame(strip, scroll_y, event_name, org, venue)

    for i in range(total_frames):
        if i < n_scroll:
            yield framed(at(i))
        elif i < n_scroll + n_hold:
            yield framed(max_scroll)
        elif closing_frame is not None:
            closing_i = i - n_scroll - n_hold
            if closing_i < fps:
                yield Image.blend(framed(max_scroll), closing_frame,
                                  closing_i / fps)
            else:
                yield closing_frame
        else:
            yield framed(max_scroll)


def encode_frames(frames, audio_in: str, audio_af: str, total_duration: float,
                  encode_tmp: Path, fps: int | None = None) -> None:
    """Mux an iterator of frames and a track into `encode_tmp`.

    Frames go to ffmpeg's stdin as raw RGB rather than through a directory of
    PNGs. Measured on 2026-08-30 against the reel this was reported on: saving
    a frame as PNG cost 107.7ms of a 115.3ms frame, so 1230 frames spent about
    two minutes compressing 2.1 GB that ffmpeg then decompressed again.

    Raw video carries no frame boundaries: the demuxer cuts the stream every
    `CANVAS_W * CANVAS_H * 3` bytes and trusts the producer. A frame of the
    wrong size or mode would not fail, it would shear every frame after it and
    encode the result happily, so the size is asserted per frame rather than
    assumed (L23, and fail loud rather than silently).
    """
    fps = FPS if fps is None else fps
    cmd = [
        "ffmpeg", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{CANVAS_W}x{CANVAS_H}",
        "-framerate", str(fps),
        "-i", "pipe:0",
        "-i", str(audio_in),
        # Select streams explicitly: without -map, ffmpeg picks the
        # highest resolution video stream across all inputs, and MP3
        # cover art counts, which can replace the reel with album art.
        "-map", "0:v:0", "-map", "1:a:0",
        # Pinned rather than left to libx264's defaults (#. 2026-08-30). Every
        # frame of a scroll is entirely new content, so the default CRF 23 spent
        # its budget re-describing the whole gallery each frame and fine detail
        # pumped between mushy and sharp, which read as more instability on top
        # of the jitter. Measured on this Mac: at CRF 18 `slow` produced the
        # same 6.4 MB as `medium` for 2.2x the encode time, so medium it is.
        "-c:v", "libx264", "-preset", "medium", "-crf", "18",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-af", audio_af,
        "-t", str(total_duration),
        str(encode_tmp),
    ]

    expected = (CANVAS_W, CANVAS_H)
    # stderr to a file rather than a pipe: a pipe nobody drains fills its buffer
    # and deadlocks against our own writes, which is a hang rather than a
    # failure and therefore the worse outcome (L110).
    with tempfile.TemporaryFile("w+") as err:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=err)
        try:
            for i, frame in enumerate(frames):
                if frame.size != expected or frame.mode != "RGB":
                    raise RuntimeError(
                        f"frame {i} is {frame.mode} {frame.size}, and the raw "
                        f"stream is cut on RGB {expected}: every later frame "
                        f"would be sheared rather than rejected")
                proc.stdin.write(frame.tobytes())
        except BrokenPipeError:
            pass  # ffmpeg is gone; its stderr below says why
        finally:
            try:
                proc.stdin.close()
            except BrokenPipeError:
                pass
            returncode = proc.wait()
        err.seek(0)
        stderr = err.read()

    if returncode != 0:
        Path(encode_tmp).unlink(missing_ok=True)
        raise RuntimeError(f"ffmpeg failed: {stderr[-500:]}")


from postroll.ai.audio_tags import THURSDAY_FALLBACK_TAGS as _DEFAULT_AUDIO_TAGS  # noqa: E402


def build_reel_preview(
    photo_paths: list[str],
    output_path: str,
    seed: int,
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
    # Keyword only from here, so `seed` can be required without reordering the
    # positional arguments every caller already passes (#1062).
    *,
    seed: int,
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

    # A strip shorter than the viewport (possible with a handful of photos)
    # has nothing to scroll: cropping past its bottom would render a black
    # band, and a 40 second motionless "scroll" is dead air. Pad the strip
    # to viewport height with the cream background and collapse the scroll
    # phase to a short hold instead.
    #
    # Against VIEWPORT_H rather than CANVAS_H since #898: the strip is cropped
    # to the viewport now, so a strip between the two heights scrolls perfectly
    # well and padding it would have stopped a real scroll dead.
    if strip_h <= VIEWPORT_H:
        padded = Image.new("RGB", (CANVAS_W, VIEWPORT_H), CREAM)
        padded.paste(strip, (0, 0))
        strip = padded
        strip_h = VIEWPORT_H
        scroll_duration = min(scroll_duration, 4.0)
        print(f"Strip shorter than viewport: padded to {CANVAS_W}x{VIEWPORT_H}, "
              f"scroll collapsed to {scroll_duration}s hold")

    total_duration = scroll_duration + HOLD_END + CLOSING_FRAME_DURATION

    # The colophon is baked into the strip (above), so the footer chrome is just a
    # cream mask now: pass no logo to it.

    # Load closing frame
    closing_frame = None
    if closing_frame_path and Path(closing_frame_path).exists():
        closing_frame = Image.open(closing_frame_path).convert("RGB")
        closing_frame = closing_frame.resize((CANVAS_W, CANVAS_H), Image.LANCZOS)

    print(f"Generating {int(total_duration * FPS)} frames "
          f"({scroll_duration}s scroll)...")

    # Encode to a temp name and rename into place atomically: a cancelled
    # render orphans its ffmpeg child, which can keep writing for seconds
    # while a replacement encode targets the same final path. The pid
    # suffix keeps the two encodes from sharing a temp file either.
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    encode_tmp = output.with_suffix(f".{os.getpid()}.tmp.mp4")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

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

        frames = scroll_frames(
            strip, event_name=event_name, org=org, venue=venue,
            scroll_duration=scroll_duration, closing_frame=closing_frame,
        )
        encode_frames(frames, audio_in, audio_af, total_duration, encode_tmp)
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
    # Required since #1062. Without one the masonry is reshuffled on every
    # run, so two renders of identical inputs are different reels and nothing
    # says so. The app mints and stores one on a day's first render.
    parser.add_argument("--seed", type=int, required=True)
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
