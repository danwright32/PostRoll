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


@dataclass(frozen=True)
class MovingTextRegion:
    """Ink that travels through the frame, so its band is found, not declared (#306).

    The Thursday reel's colophon is baked into the scrolling strip rather than
    pinned to the frame, so it passes through a different band on every frame. A
    fixed rectangle cannot address it, and a band big enough to catch it wherever
    it lands would take its background reading from whatever photography was
    passing at the time, which says nothing about the mat the mark actually sits
    on.

    `search` is where the mark can be, in canvas pixels: its horizontal extent
    from the template's own centring, and the rows between the chrome masks,
    because the header carries its own ink and finding that instead would be a
    check that passes while the colophon is missing.

    `backdrop` is the surface the mark is drawn on. It is what makes the search
    honest: a row is only a candidate when most of it is that surface, so a row
    of dark photography cannot be mistaken for the mark. Without it, any
    sufficiently dark passage of a photograph would answer the question.
    """
    name: str
    search: tuple[int, int, int, int]
    ink: tuple[int, int, int]
    backdrop: tuple[int, int, int]
    #: How much of a row must be the backdrop before it can hold the mark.
    #: Half, because the mark is ink on the mat with mat either side of it, and
    #: no row of a photograph is half a flat cream.
    min_backdrop_share: float = 0.5


def find_ink_band(frame: Image.Image, region: MovingTextRegion,
                  tolerance: int = INK_TOLERANCE) -> tuple[int, int, int, int] | None:
    """Where `region`'s mark actually sits in this frame, or None if it is not here.

    The longest run of consecutive candidate rows, so a stray qualifying row
    somewhere else in the search area cannot stretch the band across the mat
    between them and drag a clean reading out of it.
    """
    left, top, right, bottom = region.search
    patch = frame.convert("RGB").crop(region.search)
    width = right - left
    if width <= 0 or bottom - top <= 0:
        raise ValueError(f"search area for {region.name} is empty: {region.search}")

    pixels = list(patch.getdata())
    needed = int(width * region.min_backdrop_share)

    qualifying: list[bool] = []
    for row in range(bottom - top):
        line = pixels[row * width:(row + 1) * width]
        has_ink = any(_is_ink(p, region.ink, tolerance) for p in line)
        mat = sum(1 for p in line if _is_ink(p, region.backdrop, tolerance))
        qualifying.append(has_ink and mat >= needed)

    best_start = best_length = 0
    run_start = None
    for index, ok in enumerate(qualifying + [False]):
        if ok and run_start is None:
            run_start = index
        elif not ok and run_start is not None:
            if index - run_start > best_length:
                best_start, best_length = run_start, index - run_start
            run_start = None

    if best_length == 0:
        return None
    return (left, top + best_start, right, top + best_start + best_length)


def illegible_moving(frames, regions,
                     minimum: float = MIN_CONTRAST) -> list[str]:
    """Every legibility failure for ink that moves, across a sequence of frames.

    A frame where the mark is off screen has nothing to measure and is passed
    over, because on a scrolling strip that is most of them. But the render as a
    whole must show it somewhere: a mark found in no frame at all is reported,
    since that is what the wrong file (white on cream) looks like from here and
    is also what a colophon that never made it into the strip looks like. Either
    way the check proved nothing, and reporting nothing would be a pass nobody
    measured (L98).
    """
    failures: list[str] = []
    frames = list(frames)
    if not frames:
        raise ValueError("no frames to check: an empty sample proves nothing")

    for region in regions:
        readings = []
        for frame in frames:
            band = find_ink_band(frame, region)
            if band is None:
                continue
            reading = read_region(
                frame, TextRegion(region.name, band, region.ink))
            if reading.has_ink and reading.ratio is not None:
                readings.append(reading)

        if not readings:
            failures.append(
                f"{region.name}: nothing of the colour it is drawn in "
                f"{region.ink} was found on its backdrop in any of the "
                f"{len(frames)} frames sampled, so the render never shows it")
            continue

        worst = min(readings, key=lambda r: r.ratio)
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


def sample_frames_between(video_path: str | Path, start: float, end: float,
                          count: int = 5) -> list[Image.Image]:
    """`count` frames spread across [start, end] of an encoded video.

    For a window that matters more than its share of the running time (#335).
    An even spread over the whole file gives a 1.5 second dissolve one or two
    frames out of twelve, by luck rather than by intent, and a window nobody
    aimed at is a window that stops being covered the moment the timings move.

    Both ends are included, because the ends of a dissolve are where the
    outgoing and incoming designs are each at full strength and therefore the
    only moments at which either can be held to a contrast bar.
    """
    video_path = Path(video_path)
    if count < 2:
        raise ValueError("count must be at least 2: a window has two ends")
    duration = probe_duration(video_path)
    if not 0 <= start < end <= duration + 1e-6:
        raise ValueError(
            f"[{start}, {end}] is not inside {video_path.name}, which runs "
            f"{duration:.3f}s")

    stamps = [start + (end - start) * i / (count - 1) for i in range(count)]
    # Never inside the last frame: seeking to a stamp at or past its
    # presentation time decodes nothing and would raise as if the file were
    # broken. A tenth of a second is three frames at 30fps, comfortably clear of
    # the boundary without leaving the window being asked about.
    last = max(0.0, duration - 0.1)
    return [_frame_at(video_path, min(stamp, last)) for stamp in stamps]


def _frame_at(video_path: Path, stamp: float) -> Image.Image:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "frame.png"
        result = subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-ss", f"{stamp:.3f}",
             "-i", str(video_path), "-frames:v", "1", "-y", str(path)],
            capture_output=True, text=True)
        if result.returncode != 0 or not path.exists():
            raise RuntimeError(
                f"could not read a frame at {stamp:.3f}s from {video_path}: "
                f"{result.stderr.strip()}")
        with Image.open(path) as img:
            return img.convert("RGB").copy()


def mean_difference(a: Image.Image, b: Image.Image) -> float:
    """Mean absolute per-channel difference between two frames, 0 to 255.

    For telling WHICH design is on screen, which a band check cannot answer: the
    reel's plate and the closing graphic both draw dark ink on cream near the
    top of the canvas, so a band can read comfortably on either and a reel that
    silently never reached its closing graphic would pass every band it has.
    """
    if a.size != b.size:
        b = b.resize(a.size, Image.LANCZOS)
    pairs = zip(a.convert("RGB").getdata(), b.convert("RGB").getdata())
    total = sum(abs(p - q) for pa, pb in pairs for p, q in zip(pa, pb))
    return total / (a.size[0] * a.size[1] * 3)


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
