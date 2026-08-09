"""One way to ask ffprobe how long a file is (#123).

There were five of these across four files, each parsing the same output its
own way, and four of them fed `float()` the raw stdout with no look at the
return code. ffprobe writes nothing and exits non-zero on a truncated
recording, a codec it cannot open, or a path that has moved, so those raised
ValueError from inside a render, and the traceback named a float conversion
rather than the unreadable video that caused it.

The rule here is L50: a value parsed from a subprocess never feeds a
comparison directly. A failed parse returns None, and each caller decides what
None means for it (refuse, fall back to a default, skip the fade), instead of
letting a NaN compare false against every threshold and land silently on the
permissive side.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def probe_duration(path: str | Path) -> float | None:
    """Length of `path` in seconds, or None when it cannot be read.

    None covers every way this can fail, because none of them are
    distinguishable to a caller and all of them mean the same thing: there is
    no usable duration for this file.

    Zero and negative durations are None too. Zero is not a usable length,
    since every caller divides by it, trims to it, or fades from it, so
    returning it would push the failure one step downstream into arithmetic
    that cannot say what went wrong.
    """
    try:
        proc = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, text=True,
        )
    except (OSError, ValueError):
        # ffprobe missing or unrunnable. ffmpeg_check covers the toolchain at
        # startup, but a probe reached by another route must not raise out of
        # a render.
        return None

    if proc.returncode != 0:
        return None
    try:
        seconds = float(proc.stdout.strip())
    except (ValueError, TypeError):
        # A zero exit is not a promise that anything was printed, and "N/A" is
        # what ffprobe prints for a stream whose duration it cannot work out.
        return None
    return seconds if seconds > 0 else None
