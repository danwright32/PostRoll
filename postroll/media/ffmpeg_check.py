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

import re
import shutil
import subprocess
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


def _version_of(tool: str) -> str | None:
    """The version string this machine's `tool` reports, or None.

    None means "could not read it", never "there isn't one". A tool can be
    absent, can be present and refuse to run, or can print something this does
    not recognise, and all three have to arrive as unknown rather than as a
    value or as an exception: this is called to keep a record, and a record is
    worth nothing if it can quietly hold a number nobody measured (L11).
    """
    if shutil.which(tool) is None:
        return None
    try:
        proc = subprocess.run(
            [tool, "-version"], capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    # "ffmpeg version 8.1 Copyright (c) 2000-2026 the FFmpeg developers".
    # Just the version: the rest of that banner is the build's clang version and
    # a copyright year, and a line that long buries the one fact worth keeping.
    match = re.match(rf"{re.escape(tool)} version (\S+)", proc.stdout.strip())
    return match.group(1) if match else None


def ffmpeg_versions() -> dict[str, str | None]:
    """What each required tool reports, for the record a run leaves behind."""
    return {tool: _version_of(tool) for tool in REQUIRED_TOOLS}


def ffmpeg_version_line(versions: dict[str, str | None] | None = None) -> str:
    """One line for the run log saying which toolchain produced this run.

    The toolchain is presence-checked on every run and was never version-
    recorded, while this codebase has already measured version-dependent ffmpeg
    behaviour: audio_fit documents an acrossfade graph that exits 0 on CI's
    Linux build while writing a file ffprobe cannot read. A brew upgrade is
    therefore an unannounced behaviour change, and without this there is nothing
    saying which version the last good render came from (#474, L25).

    A version that could not be read says so. Leaving it out instead would make
    an unreadable toolchain indistinguishable from a recorded one, which is the
    failure this record exists to prevent.
    """
    versions = ffmpeg_versions() if versions is None else versions
    parts = [f"{tool} {versions.get(tool) or 'version unknown'}" for tool in REQUIRED_TOOLS]
    return "toolchain: " + ", ".join(parts)


def require_ffmpeg() -> None:
    """Raise with an actionable message when the toolchain is incomplete.

    Used where a still image is not an acceptable substitute for the reel that
    was asked for: a silent downgrade produces a plausible output file, which is
    the failure mode with nothing to notice.
    """
    status = ffmpeg_status()
    if not status.available:
        raise FFmpegMissingError(status.message)
