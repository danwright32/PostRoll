"""Shared test fixtures for PostRoll media generators."""

from __future__ import annotations

import os
import shutil

import pytest
from pathlib import Path
from PIL import Image, ImageFont


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


# The same shape for the reference frames (#163). They render the real
# templates, which draw with macOS system fonts, so on a runner without those
# fonts every one of them skips, and a skipped reference check is
# indistinguishable from a passing one.
REQUIRE_GOLDENS = os.environ.get("POSTROLL_REQUIRE_GOLDENS") == "1"


def mac_fonts_available() -> bool:
    """Whether the macOS system fonts the templates render with can be opened."""
    from postroll.media import design_tokens as _tokens
    try:
        ImageFont.truetype(_tokens.FONT_DETAIL, 12, index=_tokens.FONT_DETAIL_LIGHT)
        ImageFont.truetype(_tokens.FONT_SCRIPT, 12)
        return True
    except OSError:
        return False


HAVE_MAC_FONTS = mac_fonts_available()

needs_mac_fonts = pytest.mark.skipif(
    not HAVE_MAC_FONTS and not REQUIRE_GOLDENS,
    reason="renders with macOS system fonts (HelveticaNeue/SignPainter), absent on Linux CI",
)


def pytest_configure(config):
    """Stop the run outright when a required external is missing.

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
    if REQUIRE_GOLDENS and not HAVE_MAC_FONTS:
        raise pytest.UsageError(
            "POSTROLL_REQUIRE_GOLDENS is set but the macOS system fonts the "
            "templates render with are missing. Every reference-frame check "
            "would have skipped, which in CI is indistinguishable from passing."
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


# ── nothing rewrites the source tree (#497) ──────────────────────────────────
#
# Measured, not suspected: `pytest tests/ -n auto` failed on 2026-08-13 claiming
# the reel_morph template had been redesigned. It had not.
# `test_media_design_fingerprint.py` proved its guards by writing a perturbed
# copy of a real module under `postroll/media/` into place and restoring it
# afterwards, and `design_fingerprint` hashes those files off disk, so a worker
# hashing one mid-perturbation read the perturbation.
#
# Two things go wrong when a test writes into the checked-out source tree, and
# only one of them is about speed:
#
#   * It is the reason the suite cannot be run in parallel. The collision is on
#     DISK, so separate worker processes do not help, and it is a race, so it
#     fails on nobody's machine twice the same way.
#   * A run that dies between the write and the restore (an interrupt, a crash, a
#     killed worker) leaves a modified source file in the working tree.
#     `tools/check_guards.py` then refuses to run, because it will not mutate a
#     file with uncommitted changes, and the diff looks like an edit nobody made.
#
# Checked per module rather than per test: the same guarantee for a hundredth of
# the stat calls, and the module is what has to be fixed anyway.

_SOURCE_TREE = Path(__file__).resolve().parent.parent / "postroll"


def _source_tree_state() -> dict[str, tuple[int, int]]:
    state: dict[str, tuple[int, int]] = {}
    for path in _SOURCE_TREE.rglob("*.py"):
        stat = path.stat()
        state[str(path)] = (stat.st_mtime_ns, stat.st_size)
    return state


def source_tree_changes(before: dict[str, tuple[int, int]],
                        after: dict[str, tuple[int, int]]) -> list[str]:
    """Files that were written, added or removed between two snapshots.

    Pulled out of the fixture so the comparison can be exercised directly. A
    guard whose own mechanism has never been seen working is indistinguishable
    from one that reports green because it compares nothing (L1).
    """
    return sorted(
        Path(name).name for name in set(before) | set(after)
        if before.get(name) != after.get(name)
    )


@pytest.fixture(autouse=True, scope="module")
def _source_tree_is_read_only():
    before = _source_tree_state()
    yield
    touched = source_tree_changes(before, _source_tree_state())

    assert not touched, (
        "This module wrote to files in the source tree: " + ", ".join(touched)
        + ".\nEven a write that is restored afterwards is a problem: it makes the "
        "suite unsafe to run in parallel, and a run that dies before the restore "
        "leaves an edit in the working tree that nobody made. Copy what you need "
        "into tmp_path and work on the copy (#497)."
    )
