"""Can the text baked into a rendered frame actually be read? (#298)

Nothing measured this. Two defects of exactly this kind have shipped: white
brand text on the cream mat, and a divider drop shadow streaking the mat behind
the colophon. Both passed the suite, and both were invisible in stills, because
a still of the first frame does not show a label that only appears mid
animation. The detector was Dan watching an encoded video.

The measurement, per declared region of the canvas:

* Is the ink there at all? A region whose declared colour appears in no sampled
  frame is reported, because that is what white-on-cream looks like from here:
  the text is drawn, and nothing of the declared colour is on the canvas.
* Where the ink is there, how far is it from what sits behind it? The background
  is the median of the region's pixels that are NOT the ink, and the two are
  compared as a WCAG contrast ratio.

The regions come from each template's own layout constants, so a moved masthead
moves the check with it rather than leaving it asserting an empty patch of mat.
They are bands rather than glyph-tight boxes: a band cannot drift out of step
with a font fallback, and the median of a band of mat is the mat.

What this does NOT do: judge type size, spacing or the reading experience, and
it cannot see a defect that leaves the ink and its background unchanged. It
catches the class that has actually shipped, which is text that is not there to
be read.
"""

from __future__ import annotations

import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image


#: WCAG's large-text minimum. Everything here is display type over a flat mat at
#: 1080 wide, and the failures this exists to catch land near 1.0, so the bar is
#: set where it separates "cannot be read" from "can" rather than at the 4.5
#: body-text bar, which is a design decision about the palette rather than a
#: regression gate.
MIN_CONTRAST = 3.0

#: How close a pixel must be to the declared ink to count as ink, per channel
#: sum. Antialiasing means glyph pixels arrive as a gradient between ink and
#: background, so this admits the core of a stroke and not its edges.
INK_TOLERANCE = 60


def relative_luminance(rgb) -> float:
    """WCAG relative luminance, 0 (black) to 1 (white)."""
    def channel(v: float) -> float:
        v = v / 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(c) for c in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a, b) -> float:
    """WCAG contrast between two colours, 1.0 (identical) to 21.0."""
    la, lb = relative_luminance(a), relative_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


@dataclass(frozen=True)
class TextRegion:
    """A band of the canvas a template draws known ink into.

    `box` is (left, top, right, bottom) in canvas pixels, built from the
    template's own constants. `ink` is the colour the template draws with, taken
    from the design tokens it imports.
    """
    name: str
    box: tuple[int, int, int, int]
    ink: tuple[int, int, int]


@dataclass(frozen=True)
class RegionReading:
    """What one region measured on one frame."""
    name: str
    ink_pixels: int
    background: tuple[int, int, int] | None
    ratio: float | None

    @property
    def has_ink(self) -> bool:
        return self.ink_pixels > 0


def _is_ink(pixel, ink, tolerance: int) -> bool:
    return sum(abs(p - i) for p, i in zip(pixel[:3], ink)) <= tolerance


def read_region(frame: Image.Image, region: TextRegion,
                tolerance: int = INK_TOLERANCE) -> RegionReading:
    """Measure one region on one frame.

    The background is the MEDIAN of the non-ink pixels, per channel, so a
    hairline, a rule or a stray shadow inside the band cannot drag the reading:
    what the eye compares the text against is the surface most of the band is.
    """
    patch = frame.convert("RGB").crop(region.box)
    pixels = list(patch.getdata())
    if not pixels:
        raise ValueError(f"region {region.name} is empty: {region.box}")

    ink_pixels = [p for p in pixels if _is_ink(p, region.ink, tolerance)]
    background_pixels = [p for p in pixels if not _is_ink(p, region.ink, tolerance)]

    if not ink_pixels or not background_pixels:
        return RegionReading(region.name, len(ink_pixels), None, None)

    background = tuple(
        sorted(p[channel] for p in background_pixels)[len(background_pixels) // 2]
        for channel in range(3)
    )
    return RegionReading(region.name, len(ink_pixels), background,
                         contrast_ratio(region.ink, background))


def illegible(frames, regions, minimum: float = MIN_CONTRAST) -> list[str]:
    """Every legibility failure across a sequence of frames, in words.

    Two kinds, and they are reported differently because they are different
    faults. A region whose ink appears in NO frame is the invisible case: the
    text is being drawn in a colour that is not on the canvas. A region whose
    ink is present but too close to what is behind it is the washed out case.

    A region that is absent from SOME frames is not reported: the placards
    crossfade, so a frame between them genuinely has no ink to measure, and a
    check that called that a failure would fire on every correct render.
    """
    failures: list[str] = []
    frames = list(frames)
    if not frames:
        raise ValueError("no frames to check: an empty sample proves nothing")

    for region in regions:
        readings = [read_region(frame, region) for frame in frames]
        seen = [r for r in readings if r.has_ink and r.ratio is not None]
        if not seen:
            failures.append(
                f"{region.name}: the colour it is drawn in "
                f"{region.ink} appears in none of the {len(frames)} frames "
                f"sampled, so nothing of it is on the canvas")
            continue
        worst = min(seen, key=lambda r: r.ratio)
        if worst.ratio < minimum:
            failures.append(
                f"{region.name}: {region.ink} on {worst.background} reads at "
                f"{worst.ratio:.2f} to 1, under the {minimum} to 1 minimum")
    return failures


def sample_frames(video_path: str | Path, count: int = 12) -> list[Image.Image]:
    """`count` frames spread across an encoded video.

    Taken from the ENCODED file rather than from the frames handed to the
    encoder, because that file is what gets uploaded, and everything between the
    two (the pixel format, the colour range, the compression) is exactly what a
    still of the first frame cannot show.
    """
    video_path = Path(video_path)
    if count < 1:
        raise ValueError("count must be at least 1")

    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        # Even spacing across the whole file, which needs its real duration:
        # asking for "every Nth frame" would sample the opening of a long reel
        # and miss the closing frame entirely.
        duration = probe_duration(video_path)
        stamps = [duration * (i + 0.5) / count for i in range(count)]
        frames = []
        for index, stamp in enumerate(stamps):
            path = out / f"frame{index:03d}.png"
            result = subprocess.run(
                ["ffmpeg", "-nostdin", "-loglevel", "error", "-ss", f"{stamp:.3f}",
                 "-i", str(video_path), "-frames:v", "1", "-y", str(path)],
                capture_output=True, text=True)
            if result.returncode != 0 or not path.exists():
                raise RuntimeError(
                    f"could not read a frame at {stamp:.3f}s from {video_path}: "
                    f"{result.stderr.strip()}")
            with Image.open(path) as img:
                frames.append(img.convert("RGB").copy())
    return frames


def probe_duration(video_path: str | Path) -> float:
    """How long an encoded file runs, in seconds."""
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", str(video_path)],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe failed on {video_path}: {result.stderr.strip()}")
    try:
        duration = float(result.stdout.strip())
    except ValueError as exc:
        raise RuntimeError(
            f"ffprobe gave no duration for {video_path}: {result.stdout!r}") from exc
    if duration <= 0:
        raise RuntimeError(f"{video_path} reports a duration of {duration}")
    return duration


def logo_ink(logo_path: str | Path) -> tuple[int, int, int]:
    """The colour a logo actually draws in, measured from the file.

    Read rather than assumed, because the whole point of checking the colophon
    is that the wrong mark file has been shipped more than once. Only opaque
    pixels count: a mark is mostly transparency.
    """
    with Image.open(logo_path) as img:
        rgba = img.convert("RGBA")
    opaque = [p for p in rgba.getdata() if p[3] > 200]
    if not opaque:
        raise ValueError(f"{logo_path} has no opaque pixels to take a colour from")
    return tuple(
        sorted(p[channel] for p in opaque)[len(opaque) // 2] for channel in range(3)
    )
