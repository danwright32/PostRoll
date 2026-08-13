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
a separate claim: a file the job does not name executes nowhere while reporting
green.

Since #507 the job is fanned out over a matrix, so the file names live in the
matrix rather than in the pytest command. This reads them through
`ci_workflow.py`, which raises rather than returning an empty list, and both
sides of the comparison have their own emptiness guard below: a scan of the
files that finds nothing and a scan of the shards that finds nothing would each
make the comparison pass over an empty set with total confidence (L98).
"""

from __future__ import annotations

from pathlib import Path

from ci_workflow import (
    MATRIX_FILES,
    files_in_more_than_one_shard,
    reference_frame_files,
    shards,
    step_command,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"

#: This file talks ABOUT the markers without carrying one, so it excludes
#: itself, the same way the Swift side's import guard does. Otherwise the guard
#: reports itself as an uncovered file forever and says nothing about the real
#: ones.
SELF = Path(__file__).name

#: What a font-gate marker's name looks like, rather than which names exist.
#: Derived on purpose: a new marker spelled a third way is covered the day it
#: lands instead of the day somebody remembers to add it here.
MARKER_SHAPE = "mac_fonts"


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


def test_the_shard_scan_actually_finds_the_shards():
    """The other half of the derivation, guarded the same way as the scan above.

    The files used to be listed in the pytest command, and reading them off it
    was a regex. #507 moved them into a matrix, which is exactly the kind of
    change that leaves such a regex matching nothing while every assertion built
    on it goes green over an empty set: the guard would then report that CI runs
    every font-gated file at the moment it runs none of them.
    """
    found = shards()

    assert len(found) >= 2, (
        f"the reference-frame job is not fanned out any more: {found}. That is "
        "not a failure in itself, but every check below compares against these "
        "shards, so they cannot be allowed to silently become nothing.")
    assert len(reference_frame_files()) >= 4, (
        f"the shards name almost no test files: {reference_frame_files()}")


def test_the_shards_are_actually_run_by_the_step():
    """A matrix that the command ignores fans the job out and runs one file.

    The shards are only real while the pytest command interpolates them. Hardcode
    the command and the workflow still LOOKS sharded, still spends the runner
    minutes, and quietly stops running everything the matrix lists.
    """
    command = step_command()

    assert MATRIX_FILES in command, (
        f"the reference-frame step does not interpolate {MATRIX_FILES}, so the "
        f"matrix decides nothing and every shard runs the same command: "
        f"{command.strip()}")


def test_the_macos_job_runs_every_font_dependent_test_file():
    """The union of the shards, not any one of them.

    A file dropped from a shard during a rebalance is the silent failure this
    exists to catch: it runs nowhere, and a job that is not running it looks
    exactly like a job that is.
    """
    missing = sorted(font_dependent_test_files() - reference_frame_files())

    assert not missing, (
        "these test files carry @needs_mac_fonts, so they skip everywhere "
        "except the macOS job, and no shard of the macOS job runs them: "
        f"{missing}. They therefore execute nowhere in CI while reporting "
        "green. Add them to a shard in .github/workflows/swift.yml.")


def test_no_test_file_is_run_by_two_shards():
    """The shards are a partition, not a selection.

    A file in two shards is rendered twice on two billed runners, and it makes
    the balance the shard durations were measured for silently wrong, which is
    invisible because every check still passes.
    """
    duplicated = files_in_more_than_one_shard()

    assert not duplicated, (
        "these test files are run by more than one shard of the reference-frame "
        f"job, so CI pays to render them twice: {duplicated}")
