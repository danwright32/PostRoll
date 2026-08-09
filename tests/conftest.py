"""Shared test fixtures for PostRoll media generators."""

from __future__ import annotations

import os
import shutil

import pytest
from pathlib import Path
from PIL import Image


# ── ffmpeg gate (#106) ────────────────────────────────────────────────────────
#
# One definition, imported by every suite with end-to-end ffmpeg tests, rather
# than the same two lines copied into three files where they can drift.
#
# The end-to-end reel and audio-fit tests skip when ffmpeg is absent, which is
# right on a machine that does not have it and wrong in CI, where a silent skip
# looks exactly like a pass. Setting POSTROLL_REQUIRE_FFMPEG=1 removes the skip,
# so a runner without ffmpeg fails loudly instead of reporting green having run
# none of them.

def ffmpeg_required(env: dict[str, str] | None = None) -> bool:
    """Whether a missing ffmpeg should fail rather than skip."""
    raw = (env if env is not None else os.environ).get("POSTROLL_REQUIRE_FFMPEG", "")
    return raw.strip().lower() not in ("", "0", "false", "no")


def should_skip_ffmpeg_tests(*, have_ffmpeg: bool, require_ffmpeg: bool) -> bool:
    """Skip only when ffmpeg is genuinely absent AND nobody demanded it.

    Pure so the three states can be asserted directly: present (run), absent on
    a dev machine (skip), absent where it was required (do not skip, so the run
    fails and the absence is visible).
    """
    return not have_ffmpeg and not require_ffmpeg


HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
REQUIRE_FFMPEG = ffmpeg_required()

needs_ffmpeg = pytest.mark.skipif(
    should_skip_ffmpeg_tests(have_ffmpeg=HAVE_FFMPEG, require_ffmpeg=REQUIRE_FFMPEG),
    reason="ffmpeg/ffprobe not installed",
)


def pytest_configure(config):
    """Stop the run outright when ffmpeg is required but missing.

    In `pytest_configure` rather than at collection so the reason is actually
    printed. Raised later, pytest reports only "no tests ran" and a bare exit
    code 4, which fails the build without saying why.
    """
    if REQUIRE_FFMPEG and not HAVE_FFMPEG:
        raise pytest.UsageError(
            "POSTROLL_REQUIRE_FFMPEG is set but ffmpeg/ffprobe are not on PATH. "
            "The end-to-end media tests would have skipped silently, which in CI "
            "is indistinguishable from passing. Install ffmpeg on the runner."
        )


@pytest.fixture
def tmp_output(tmp_path):
    """Temporary output directory."""
    return tmp_path


@pytest.fixture
def sample_photo(tmp_path):
    """Create a sample landscape photo (2000x1332) simulating a concert shot."""
    img = Image.new("RGB", (2000, 1332), (120, 80, 60))  # warm brown tone
    path = tmp_path / "sample.jpg"
    img.save(str(path), "JPEG")
    return str(path)


@pytest.fixture
def sample_photo_dark(tmp_path):
    """Create a dark sample photo simulating a dark concert hall."""
    img = Image.new("RGB", (2000, 1332), (25, 20, 18))
    path = tmp_path / "sample_dark.jpg"
    img.save(str(path), "JPEG")
    return str(path)


@pytest.fixture
def sample_photo_bright(tmp_path):
    """Create a bright sample photo simulating a well-lit venue."""
    img = Image.new("RGB", (2000, 1332), (220, 200, 180))
    path = tmp_path / "sample_bright.jpg"
    img.save(str(path), "JPEG")
    return str(path)


@pytest.fixture
def sample_logo(tmp_path):
    """Create a sample logo PNG with transparency."""
    img = Image.new("RGBA", (1935, 480), (0, 0, 0, 255))
    path = tmp_path / "logo.png"
    img.save(str(path), "PNG")
    return str(path)
