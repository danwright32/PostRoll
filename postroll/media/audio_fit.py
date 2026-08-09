"""
PostRoll — fit an audio track to an exact reel length.

A reel needs an audio bed exactly as long as the video. The source track is
often shorter (a short uploaded clip) or longer (a full song). This renders a
temp WAV of the precise target duration:

- Source longer than / equal to the reel: trim to length.
- Source shorter than the reel: loop it, crossfading each repeat's tail into
  the next head (`acrossfade`) so the seam is inaudible rather than a hard,
  jarring restart.

The caller applies its own fade-out and mux, so this stays fade-agnostic.
ffmpeg only — no extra Python dependencies.
"""

from __future__ import annotations

import math
import subprocess
from pathlib import Path

# Seconds blended at each loop seam. Kept short so you don't hear the end of
# the track playing over its own beginning (a long crossfade of music against
# itself sounds like two takes at once); just long enough to avoid a click.
DEFAULT_CROSSFADE = 0.5

from .probe import probe_duration  # noqa: E402


def audio_duration(path: str | Path) -> float | None:
    """Length of `path` in seconds, or None if it can't be read.

    Kept as a name because callers read as audio code, but the behaviour is
    the shared probe: this file had the only safe version of it, and the other
    four sites are now folded onto the same one (#123).
    """
    return probe_duration(path)


def _loop_copies(audio_len: float, duration: float, crossfade: float) -> int:
    """Number of copies to chain so the crossfaded result spans `duration`.

    Chaining N copies that overlap by `crossfade` yields
    N*audio_len - (N-1)*crossfade seconds. Solve for the smallest N covering
    `duration`, then add one copy of headroom (the final atrim caps any excess).
    """
    span = audio_len - crossfade
    if span <= 0:
        # Crossfade as long as the clip itself: each extra copy adds almost
        # nothing, so fall back to a generous count keyed off the raw length.
        return max(2, math.ceil(duration / max(audio_len, 0.1)) + 1)
    return max(2, math.ceil((duration - crossfade) / span) + 1)


def _loop_filtergraph(copies: int, crossfade: float, duration: float) -> str:
    """filter_complex chaining `copies` separate inputs of the same file with
    crossfaded seams, then trimming to exactly `duration`.

    Each copy is its OWN `-i` input (see `_loop_command`) rather than branches
    of one `asplit`. acrossfade has to buffer the tail of its first input while
    reading the head of its second, and when both branches come from a single
    decoder that pattern is version dependent: on the Linux ffmpeg in CI it
    exits 0 and writes a file ffprobe cannot read, which then fell back to
    silence padding, the exact thing this function exists to avoid. Separate
    inputs give each side its own decoder, which is what the filter expects.
    """
    parts = []
    prev = "0:a"
    for i in range(1, copies):
        nxt = f"x{i}"
        # Equal-power curve (qsin) on both sides so the seam holds a constant
        # perceived loudness instead of dipping ~6 dB through a linear blend.
        parts.append(f"[{prev}][{i}:a]acrossfade=d={crossfade:.3f}:c1=qsin:c2=qsin[{nxt}]")
        prev = nxt
    parts.append(f"[{prev}]atrim=0:{duration:.3f}[aout]")
    return ";".join(parts)


def _loop_command(src: str, out_path: str, *, copies: int, graph: str,
                  duration: float) -> list[str]:
    """The ffmpeg call for `graph`: the source repeated as `copies` inputs."""
    cmd = ["ffmpeg", "-y", "-loglevel", "error"]
    for _ in range(copies):
        cmd += ["-i", src]
    cmd += ["-filter_complex", graph, "-map", "[aout]",
            "-t", f"{duration:.3f}", "-c:a", "pcm_s16le", out_path]
    return cmd


def _run(cmd: list[str]) -> bool:
    return subprocess.run(cmd, capture_output=True, text=True).returncode == 0


def _usable(path: str) -> bool:
    """Whether ffmpeg actually produced a readable audio file.

    An exit code of 0 is not proof of output. On the Linux ffmpeg in CI the
    crossfaded loop graph exits 0 and writes a file ffprobe cannot read, and
    because success was claimed from the exit code alone, a reel shipped with
    silent or broken audio and nothing said so. Checking the artifact turns
    that into either the trim fallback or a loud error.
    """
    return audio_duration(path) is not None


def fit_audio_to_duration(
    src: str | Path,
    out_path: str | Path,
    *,
    duration: float,
    crossfade: float = DEFAULT_CROSSFADE,
) -> str:
    """Render `src` to `out_path` (WAV) at exactly `duration` seconds.

    Loops with crossfaded seams when `src` is shorter than `duration`, otherwise
    trims. Returns `out_path`. Raises RuntimeError only if even the plain
    trim/pad fallback fails (i.e. the source is unreadable).
    """
    src, out_path = str(src), str(out_path)
    length = audio_duration(src)

    if length is not None and length < duration:
        cross = min(crossfade, length / 2)
        copies = _loop_copies(length, duration, cross)
        graph = _loop_filtergraph(copies, cross, duration)
        looped = _loop_command(src, out_path, copies=copies, graph=graph,
                               duration=duration)
        if _run(looped) and _usable(out_path):
            return out_path
        # Fall through to trim/pad if the loop graph fails for any reason.

    # Long, equal, unprobeable, or loop fallback: trim to length and pad with
    # silence only if the source turns out shorter than expected.
    trimmed = ["ffmpeg", "-y", "-loglevel", "error", "-i", src,
               "-af", f"atrim=0:{duration:.3f},apad",
               "-t", f"{duration:.3f}", "-c:a", "pcm_s16le", out_path]
    if _run(trimmed) and _usable(out_path):
        return out_path

    Path(out_path).unlink(missing_ok=True)
    raise RuntimeError(f"Could not fit audio to {duration:.1f}s: {src}")
