"""Every check that needs macOS fonts is actually run by the macOS job.

A font-gate marker skips a test unless the runner has SignPainter and
HelveticaNeue, which only the macOS job has. So a font-dependent check placed in
a file that job does not invoke never executes anywhere: it passes locally on
Dan's Mac, and on Linux it skips. A skipped check is indistinguishable from a
passing one, which is the failure mode `swift.yml` was written to close.

There is more than one such marker, which is why this matches on the SHAPE of
the name rather than on a spelling. `conftest.py` exports `needs_mac_fonts`, and
`test_gallery_alignment.py` defines its own `requires_mac_fonts` locally. The
first version of this guard looked for the conftest spelling only and reported
green while four font-gated checks in that second file ran nowhere, which is the
same blindness it exists to prevent, one level up (L96): a guard driven by the
name somebody remembered checks only what that name covers.

That is exactly what happened. `tests/test_frame_legibility.py` shipped in #298
and grew the scrolling colophon check in #306, and the macOS job invoked only
`tests/test_golden_frames.py` the whole time, so neither guard had ever run in
CI. Both were real and both were proven on this Mac; neither was wired (L3).

Derived from the files rather than from a list somebody maintains beside the
workflow: a hand-kept registry checks only what it lists, so the file missing
from it is exempt from the very check meant to catch it (L96). This walks
`tests/` for the marker and asserts the workflow names every file that carries
it.

This used to check two things: that the job RUNS every font-gated file, and that
it TRIGGERS on changes to them. The second is gone with the paths filter it was
about (#431), since every pull request now runs the job whatever it touched, and
`test_ci_gates.py` holds that. Running them is still checked here, because that is
a separate claim: a file the job does not name in its pytest command executes
nowhere while reporting green.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"

#: This file talks ABOUT the markers without carrying one, so it excludes
#: itself, the same way the Swift side's import guard does. Otherwise the guard
#: reports itself as an uncovered file forever and says nothing about the real
#: ones.
SELF = Path(__file__).name

#: What a font-gate marker's name looks like, rather than which names exist.
#: Derived on purpose: a new marker spelled a third way is covered the day it
#: lands instead of the day somebody remembers to add it here.
MARKER_SHAPE = "mac_fonts"


def _workflow_text() -> str:
    if not WORKFLOW.exists():
        pytest.fail(
            f"{WORKFLOW} is missing, so nothing here can say whether the "
            "font-dependent checks run in CI. That is a failure rather than a "
            "skip: a guard that cannot read its subject has measured nothing.")
    return WORKFLOW.read_text(encoding="utf-8")


def font_dependent_test_files() -> set[str]:
    """Test files carrying any font-gate marker, read off the directory."""
    found = set()
    for path in sorted(TESTS_DIR.glob("test_*.py")):
        if path.name == SELF:
            continue
        if MARKER_SHAPE in path.read_text(encoding="utf-8"):
            found.add(path.name)
    return found


def test_the_scan_actually_finds_font_dependent_files():
    # Guards the derivation: a scan matching nothing would make the assertion
    # below pass with total confidence while checking no file at all (L98).
    found = font_dependent_test_files()

    assert len(found) >= 2, (
        "the scan for font-dependent test files found almost nothing, so the "
        f"check below is vacuous: {sorted(found)}")


def test_the_macos_job_runs_every_font_dependent_test_file():
    workflow = _workflow_text()
    # The pytest invocation only, not the whole file: a filename appearing in a
    # `paths` filter means the job TRIGGERS on it, which is a different claim
    # from the job RUNNING it.
    #
    # Read across newlines, because a command long enough to list several files
    # gets wrapped into a YAML folded block and a single-line match would then
    # see `run: >` and nothing else. That is not hypothetical: it happened the
    # first time a third file was added here.
    invocations = "\n".join(re.findall(r"pytest[\s\S]{0,400}?-ra", workflow))

    missing = sorted(f for f in font_dependent_test_files() if f not in invocations)

    assert not missing, (
        "these test files carry @needs_mac_fonts, so they skip everywhere "
        "except the macOS job, and the macOS job does not run them: "
        f"{missing}. They therefore execute nowhere in CI while reporting "
        "green. Add them to the pytest command in .github/workflows/swift.yml.")
