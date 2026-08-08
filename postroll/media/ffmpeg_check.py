"""Whether the ffmpeg toolchain this app depends on is actually installed.

ffmpeg and ffprobe are hard runtime dependencies of every reel, and neither is a
Python package, so nothing in requirements.txt installs them and nothing
declared them (#87). The only check was a per-call `shutil.which("ffmpeg")`
whose failure printed a log line and then rendered a still image where a reel
was asked for, so the run reported success with the reels quietly absent.
ffprobe was never checked at all.

One check, naming each missing tool and carrying the command that fixes it.
"""

from __future__ import annotations

import shutil
from dataclasses import dataclass, field

#: What the app actually shells out to. ffmpeg encodes, ffprobe reads durations.
REQUIRED_TOOLS = ("ffmpeg", "ffprobe")

#: The one command that installs both on the Mac this runs on.
INSTALL_HINT = "brew install ffmpeg"


class FFmpegMissingError(RuntimeError):
    """The ffmpeg toolchain isn't installed, so a video render can't happen."""


@dataclass(frozen=True)
class FFmpegStatus:
    missing: list[str] = field(default_factory=list)

    @property
    def available(self) -> bool:
        return not self.missing

    @property
    def message(self) -> str | None:
        """What to tell the user, or None when everything is present."""
        if not self.missing:
            return None
        names = " and ".join(self.missing)
        verb = "is" if len(self.missing) == 1 else "are"
        return (
            f"{names} {verb} not installed, so video can't be rendered. "
            f"Install with: {INSTALL_HINT}"
        )


def ffmpeg_status() -> FFmpegStatus:
    """Which of the required tools are missing from PATH."""
    return FFmpegStatus(missing=[t for t in REQUIRED_TOOLS if shutil.which(t) is None])


def require_ffmpeg() -> None:
    """Raise with an actionable message when the toolchain is incomplete.

    Used where a still image is not an acceptable substitute for the reel that
    was asked for: a silent downgrade produces a plausible output file, which is
    the failure mode with nothing to notice.
    """
    status = ffmpeg_status()
    if not status.available:
        raise FFmpegMissingError(status.message)
