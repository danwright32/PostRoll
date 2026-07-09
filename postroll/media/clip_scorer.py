"""
PostRoll: Friday clip reel Stage 1, the deterministic clip scorer.

No AI cost. Screens out unusable footage (out-of-focus, or frames that are
just incoherent noise rather than real content) before Stage 2's Claude call
ever sees a clip, and finds each usable clip's best trim window: the
contiguous stretch that actually clears the quality bar, not just its raw
bounds.

Two signals per sampled frame:
- Sharpness: Pillow edge-detection stddev on the grayscale frame. Higher
  means more real detail in focus.
- Motion coherence: mean pixel delta between consecutive frames. This is
  NOT "more motion is better". A locked-off or slow-pan shot (Dan's actual
  shooting conditions: low-light concert/theater) should stay valid at
  near-zero motion. It exists to catch the opposite failure: pure noise
  reads as "sharp" per frame (lots of edge energy) but is completely
  incoherent frame to frame, unlike any real footage, however shaky. A high
  motion delta between EVERY consecutive frame pair is what noise looks
  like; real motion (even fast) still correlates neighboring frames.

ffmpeg/ffprobe only for frame extraction. Pillow (already a dependency) for
scoring, no new dependency (no cv2/opencv in this repo).
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter, ImageStat

# How many frames to sample across a clip. Evenly spaced.
SAMPLE_COUNT = 8

# Frames are downscaled to this long edge before scoring. Edge-detection
# stddev scales with frame dimensions, not perceptual sharpness (a hard edge
# spans more pixels at higher resolution, so the per-pixel gradient reads
# lower). Real bug found 2026-07-08 against 17 real 4K clips from an actual
# event, every one scored below MIN_SHARPNESS despite being genuinely in
# focus. MIN_SHARPNESS/MAX_COHERENT_MOTION below were calibrated against
# fixtures at roughly this size; every clip must be normalized to it first
# so a source's native resolution never changes its score.
SCORING_LONG_EDGE = 320

# A frame's edge-detection stddev below this reads as out-of-focus or blank.
# Calibrated against synthetic fixtures (after normalizing to SCORING_LONG_EDGE):
# a solid-color frame lands ~15 (H.264 compression noise, not real detail),
# real detail (even a simple moving-gradient test pattern) lands ~45+.
MIN_SHARPNESS = 25.0

# Mean pixel delta between consecutive frames above this reads as incoherent
# (noise), not real motion. The synthetic moving-gradient fixture lands
# ~5-7 and pure per-frame random noise lands ~95, but real camera footage
# (busy real scenes, ordinary handheld micro-shake, autofocus) sits well
# above the gradient fixture even when genuinely usable: measured 13-66
# across 17 real clips from an actual event, 2026-07-08. Set with headroom
# above that real range and comfortable margin below the noise fixture.
MAX_COHERENT_MOTION = 70.0

# A valid_trim window shorter than this isn't worth keeping.
MIN_VALID_TRIM_SECONDS = 2.0

# Stage 1 must find at least this many usable clips to attempt a reel.
MIN_USABLE_CLIPS = 3


class InsufficientClipsError(RuntimeError):
    """Raised when fewer than MIN_USABLE_CLIPS clips pass the quality screen."""


def clip_duration(path: str | Path) -> float | None:
    """Length of `path` in seconds via ffprobe, or None if it can't be read."""
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None
    try:
        seconds = float(proc.stdout.strip())
    except ValueError:
        return None
    return seconds if seconds > 0 else None


def _sample_times(duration: float, count: int) -> list[float]:
    if count <= 1:
        return [duration / 2]
    step = duration / count
    return [step * (i + 0.5) for i in range(count)]


def _extract_frame(path: Path, t: float, out: Path) -> bool:
    proc = subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-ss", str(t), "-i", str(path),
         "-frames:v", "1", str(out)],
        capture_output=True,
    )
    return proc.returncode == 0 and out.exists()


def _normalize_for_scoring(frame: Image.Image) -> Image.Image:
    """Downscale to SCORING_LONG_EDGE (never upscale) so a clip's native
    resolution can't shift its sharpness/motion scores away from the basis
    MIN_SHARPNESS/MAX_COHERENT_MOTION were calibrated against."""
    frame = frame.copy()
    frame.thumbnail((SCORING_LONG_EDGE, SCORING_LONG_EDGE), Image.LANCZOS)
    return frame


def _sample_frames(path: Path, duration: float, count: int) -> list[Image.Image]:
    frames: list[Image.Image] = []
    with tempfile.TemporaryDirectory(prefix="postroll-clipscore-") as tmp:
        tmp_path = Path(tmp)
        for i, t in enumerate(_sample_times(duration, count)):
            out = tmp_path / f"frame_{i:03d}.png"
            if _extract_frame(path, t, out):
                frame = Image.open(out).convert("RGB")
                frames.append(_normalize_for_scoring(frame))
    return frames


def _sharpness(frame: Image.Image) -> float:
    gray = frame.convert("L")
    edges = gray.filter(ImageFilter.FIND_EDGES)
    return ImageStat.Stat(edges).stddev[0]


def _motion(a: Image.Image, b: Image.Image) -> float:
    diff = ImageChops.difference(a.convert("L"), b.convert("L"))
    return ImageStat.Stat(diff).mean[0]


def _longest_valid_run(sharpness: list[float], motion: list[float]) -> tuple[int, int] | None:
    """Longest contiguous run of frame indices [start, end] (inclusive) where
    every frame clears MIN_SHARPNESS and every gap to the next frame in the
    run stays under MAX_COHERENT_MOTION. Returns None if no frame qualifies."""
    best: tuple[int, int] | None = None
    run_start: int | None = None
    for i, s in enumerate(sharpness):
        if s < MIN_SHARPNESS:
            run_start = None
            continue
        if run_start is None:
            run_start = i
        else:
            gap_ok = motion[i - 1] <= MAX_COHERENT_MOTION
            if not gap_ok:
                run_start = i
        if best is None or (i - run_start) > (best[1] - best[0]):
            best = (run_start, i)
    return best


def score_clip(path: str | Path) -> dict:
    """Score one clip. Returns
    {path, duration, usable, score, valid_trim: (in, out) | None}."""
    path = Path(path)
    duration = clip_duration(path)
    if duration is None:
        return {"path": str(path), "duration": 0.0, "usable": False, "score": 0.0, "valid_trim": None}

    times = _sample_times(duration, SAMPLE_COUNT)
    frames = _sample_frames(path, duration, SAMPLE_COUNT)
    if len(frames) < 2:
        return {"path": str(path), "duration": duration, "usable": False, "score": 0.0, "valid_trim": None}
    times = times[:len(frames)]

    sharpness = [_sharpness(f) for f in frames]
    motion = [_motion(frames[i], frames[i + 1]) for i in range(len(frames) - 1)]

    run = _longest_valid_run(sharpness, motion)
    if run is None:
        return {"path": str(path), "duration": duration, "usable": False, "score": 0.0, "valid_trim": None}

    start_idx, end_idx = run
    trim_in = times[start_idx]
    trim_out = times[end_idx]
    if trim_out - trim_in < MIN_VALID_TRIM_SECONDS:
        return {"path": str(path), "duration": duration, "usable": False, "score": 0.0, "valid_trim": None}

    window_sharpness = sharpness[start_idx:end_idx + 1]
    score = sum(window_sharpness) / len(window_sharpness)

    return {
        "path": str(path),
        "duration": duration,
        "usable": True,
        "score": score,
        "valid_trim": (trim_in, trim_out),
    }


def score_clips(paths: list[str | Path], minimum_usable: int = MIN_USABLE_CLIPS) -> list[dict]:
    """Score every clip in `paths`. Raises InsufficientClipsError if fewer
    than `minimum_usable` come back usable, rather than silently returning
    an unusable batch for Stage 2 to build a reel from."""
    scored = [score_clip(p) for p in paths]
    usable_count = sum(1 for s in scored if s["usable"])
    if usable_count < minimum_usable:
        raise InsufficientClipsError(
            f"only {usable_count} of {len(paths)} clips usable, need at least {minimum_usable}"
        )
    return scored
