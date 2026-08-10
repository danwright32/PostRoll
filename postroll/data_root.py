"""Where the app keeps its data, answered once.

The Swift app exports `POSTROLL_DATA_DIR` from `AppPaths.root`, so anything the
Python side writes lands beside everything else the app owns. The fallback is
the same post-migration location the app itself uses, for CLI and test runs
launched by hand.

This exists because the answer was being written out longhand in each module
that needed it (`usage_log`, then `cap_signals` through it, then the audio
cache which had never been told and was still writing to `~/.postroll`). One
copy of a path is a path; three copies are three places to forget.
"""

from __future__ import annotations

import os
from pathlib import Path


def data_root() -> Path:
    """The directory holding the app's data. Not created here."""
    override = (os.environ.get("POSTROLL_DATA_DIR") or "").strip()
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "PostRoll"


def running_under_test() -> bool:
    """Whether this process is a test run.

    `PYTEST_CURRENT_TEST` is set by pytest for the duration of each test, so it
    is true exactly while a test is executing and false in the app's own
    subprocess, which is the distinction that matters.

    Used by anything that would otherwise reach a real home-folder path from a
    test. Its own function so the behaviour on both sides of it can be asserted.
    """
    return "PYTEST_CURRENT_TEST" in os.environ
