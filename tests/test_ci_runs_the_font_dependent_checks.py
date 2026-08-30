"""Every check that needs macOS fonts is actually run by the macOS job.

A font-gate marker skips a test unless the runner has SignPainter and
HelveticaNeue. A skipped check is indistinguishable from a passing one, which is
the failure mode `swift.yml` was written to close.

What this job is for, stated accurately (#766). It is NOT that a file it does
not name executes nowhere: `tests.yml`'s `macos` job runs the WHOLE suite on
macos-15 and is a required check, so a font-gated file runs there whether or not
a shard names it. That was true from #571 onwards and the reason recorded here
went on saying otherwise, which is the kind of sentence that gets a gate loosened
on the strength of a comment (L210).

The real reason is one line of that job: it sets `POSTROLL_REQUIRE_FFMPEG` and
NOT `POSTROLL_REQUIRE_GOLDENS`. That second variable is what turns a missing
system face from a skip into a hard failure (`tests/conftest.py`). So the whole
suite run on the Mac executes these files today and cannot tell you if it ever
stops: if the runner image dropped SignPainter, every font-gated check there
would skip and that job would stay green. This job sets both variables, so it is
the only place where a font-gated file going quiet is a failure.

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
`test_ci_gates.py` holds that. Running them is still checked here, for the reason
given above: this is the only job where a font-gated file going quiet fails.

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
        "these test files carry @needs_mac_fonts and no shard of the "
        f"reference-frame job runs them: {missing}. They do still run in "
        "tests.yml's `macos` job, which runs the whole suite on a Mac, but that "
        "job does not set POSTROLL_REQUIRE_GOLDENS, so if the runner ever lost "
        "the system faces every one of them would skip there and report green. "
        "This job is the only place a font-gated file going quiet is a failure. "
        "Add them to a shard in .github/workflows/swift.yml.")


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


# ── and runs them in exactly ONE place (#995) ─────────────────────────────────
#
# The Mac leg used to run the whole suite, so every file above rendered twice on
# macos-15: once in a shard here and once there. #571 decided that deliberately
# and priced it at "about 200s of wall clock and nothing else" because the
# runners are free on a public repo.
#
# They are free in money and not in queue. Measured over the two weeks to
# 2026-08-30: the shards and the Mac leg together held 28% of this repository's
# macOS runner-minutes while other jobs waited on GitHub's five concurrent macOS
# runners, and these nine files are 1,433s of the suite's 2,050s of recorded
# test time, 70% of it.
#
# The tests below hold the shape that replaced it. The one that matters is the
# last: the ignore list has to be DERIVED from the matrix, because a copy drifts
# in a direction nobody sees. A file dropped from the matrix and still named in
# a hand-written ignore list runs in NEITHER place, with each side believing the
# other has it, and both jobs stay green (L41, L98).

from ci_workflow import IGNORE_FLAG, macos_leg_ignores  # noqa: E402

TESTS_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "tests.yml"


def _macos_job() -> str:
    """The `macos` job's body, so a claim about it cannot be met by the Linux
    leg sitting in the same file (L135)."""
    import re
    text = TESTS_WORKFLOW.read_text(encoding="utf-8")
    settings = "\n".join(line for line in text.splitlines()
                         if not line.strip().startswith("#"))
    match = re.search(r"^  macos:[ \t]*$(.*?)(?=^  \S|\Z)", settings, re.M | re.S)
    assert match, (
        "there is no `macos:` job in tests.yml any more, so every check here is "
        "reading nothing (L98)")
    return match.group(1)


def test_the_ignore_list_covers_every_file_the_shards_render():
    ignored = macos_leg_ignores()
    assert len(ignored) == len(reference_frame_files()), (
        f"the Mac leg's ignore list and the matrix disagree about how many "
        f"files there are: {ignored} against {sorted(reference_frame_files())}")
    for name in reference_frame_files():
        assert f"--ignore=tests/{name}" in ignored, (
            f"{name} is rendered by a shard and still rendered by the Mac leg, "
            "so it costs a macOS runner twice on every pull request")


def test_the_ignore_list_is_never_silently_empty():
    """An empty list is a Mac leg that quietly went back to running everything,
    which reads as a slow job rather than as a broken derivation (L98)."""
    import pytest as _pytest
    with _pytest.raises(AssertionError):
        macos_leg_ignores("jobs:\n  reference-frames:\n    steps: []\n")


def test_the_mac_leg_asks_for_the_list_rather_than_spelling_it():
    """The whole point. A hand-written copy beside the matrix drifts, and the
    bad direction is silent: a file dropped from the matrix and still ignored
    here runs in neither place while both jobs stay green (L41)."""
    job = _macos_job()
    assert IGNORE_FLAG in job, (
        f"the Mac leg does not ask ci_workflow.py for its ignore list "
        f"({IGNORE_FLAG}), so whatever it skips is a second copy of the matrix "
        "that nothing keeps in step with the first")


def test_the_list_it_asks_for_actually_reaches_pytest():
    """Asking for the list and then not using it is the same job it was before.

    Written after the check above SURVIVED its mutation: replacing the pytest
    invocation with a plain `pytest -v -n auto` left the line that computes the
    list sitting untouched above it, so the guard went green over a Mac leg that
    computed nine ignore arguments and threw them away (L100, L178).

    So this follows the path: whatever file the generating command redirects
    into has to be the file the pytest invocation reads from.
    """
    import re
    job = _macos_job()
    written = re.search(rf"{re.escape(IGNORE_FLAG)}\s*>\s*(\S+)", job)
    assert written, (
        f"the Mac leg runs ci_workflow.py {IGNORE_FLAG} but does not redirect "
        "it anywhere, so nothing can be reading the list it prints")
    destination = written.group(1)

    # The generating line is excluded explicitly. Written without that, this
    # test matched it and passed: the flag is spelled `--pytest-ignore`, so the
    # line that PRODUCES the list contains the substring "pytest" and the
    # destination, and answered as its own consumer. A success check that
    # matches a substring of the thing being talked about also matches the line
    # talking about it (L156). Caught by the mutation this test was written for
    # surviving twice.
    consuming = [line for line in job.splitlines()
                 if "pytest" in line and destination in line
                 and IGNORE_FLAG not in line]
    assert consuming, (
        f"the Mac leg writes its ignore list to {destination} and no pytest "
        f"invocation reads it back, so the list is computed and discarded and "
        f"the job renders every file the shards render all over again. The "
        f"pytest lines it does have: "
        f"{[l.strip() for l in job.splitlines() if 'pytest' in l]}")


def test_the_mac_leg_names_no_test_file_of_its_own():
    """Derived means derived. A single filename appearing in the job is the copy
    starting, and it would be correct on the day it was written."""
    job = _macos_job()
    named = [name for name in reference_frame_files() if name in job]
    assert not named, (
        f"the Mac leg spells these test file names itself: {named}. They come "
        "from the reference-frame matrix, and a second spelling of them is a "
        "list that will disagree with it")


def test_every_font_dependent_file_still_runs_somewhere():
    """The rule the two halves add up to, asserted as one thing.

    Each font-gated file is named by exactly one shard, and the Mac leg ignores
    exactly the files the shards name. Together that is "runs in exactly one
    place". Checked here rather than left to the reader of two other tests,
    because the failure this guards against is a file that falls between them
    (L178: two conditions over one body of text prove neither half).
    """
    gated = font_dependent_test_files()
    rendered = reference_frame_files()
    assert gated, "the scan found no font-gated files, so this is vacuous (L98)"

    nowhere = sorted(gated - rendered)
    assert not nowhere, (
        f"these files need macOS fonts and no shard renders them, and the Mac "
        f"leg no longer runs everything, so they now run NOWHERE: {nowhere}")

    assert not files_in_more_than_one_shard(), (
        "a font-gated file is named by more than one shard, so it renders twice "
        "again, which is what #995 removed")
