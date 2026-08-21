"""The fast local suite deselects the expensive files and nothing else (#413).

The full Python suite is a few minutes on this Mac, and most of that is the
handful of files that render real reels through ffmpeg and read pixels back out.
That is long enough that it stopped being run locally at all on 2026-08-12,
which is how a break gets found after a push rather than before.

So there is a fast target that skips them. Two things have to stay true or it
becomes a way of not running the tests:

* The expensive set is DERIVED from a MEASUREMENT, not kept as a second list
  beside the code. A hand-kept registry checks only what it lists, so the file
  missing from it is exempt from the very check meant to catch it (L96).
* CI still runs everything. The fast target is for the loop between edits; it is
  not the gate.

What it is derived FROM changed in #766. It used to come from `swift.yml`'s
reference-frame matrix, which is the set of files needing macOS system fonts,
on the premise that the matrix is "where the time goes". That made one marker
name two different properties: a file is font dependent, meaning it must run
where the faces are, or it is expensive, meaning the fast loop may skip it, and
a file can be either without being both (L118).

The premise was also wrong in both directions, measured on 2026-08-21:
`test_generate_media_friday_clips.py` is 3.3% of the run and is in no shard, so
the fast run paid for it every time, while `test_story_title_clamp.py` is 0.5%
and was skipped because it happens to need the faces.

So the set now comes from `tests/file_durations.py`, reading what
`tools/record_test_durations.py` measured. Font dependence keeps its own
derivation, off the marker in the file itself, in
`tests/test_ci_runs_the_font_dependent_checks.py`.
"""

from __future__ import annotations

import re
from pathlib import Path


from file_durations import (
    EXPENSIVE_SHARE,
    GAP_ABOVE,
    GAP_BELOW,
    expensive,
    files_on_disk,
    recorded,
    shares,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
MAKEFILE = REPO_ROOT / "Makefile"
PYPROJECT = REPO_ROOT / "pyproject.toml"

#: The marker that takes a file out of the fast run.
SLOW = "pytest.mark.slow"


def test_the_measurement_actually_found_some_expensive_files():
    """If this finds nothing, every check below is measuring an empty set."""
    files = expensive()
    assert len(files) >= 2, (
        f"only {sorted(files)} measure at or above {EXPENSIVE_SHARE:.0%} of "
        "the run, so the "
        "fast target is skipping almost nothing and the checks below prove "
        "almost nothing. Re-record with tools/record_test_durations.py.")


def test_the_measurement_did_not_swallow_the_whole_suite():
    """The other end of the same guard.

    A record in which everything is expensive would take the entire suite out of
    the fast run, which looks exactly like a very fast suite (#413).
    """
    files = expensive()
    assert len(files) < len(recorded()) / 2, (
        f"{len(files)} of {len(recorded())} measured files are over the floor, "
        "so the fast run is skipping most of the suite")


def test_the_record_names_only_files_that_still_exist():
    """A record naming a file that has gone is a record nobody re-took.

    It matters in one direction in particular: a file RENAMED rather than
    deleted keeps its old entry deciding nothing while the new name is
    unmeasured, so an expensive file quietly rejoins the fast run.
    """
    on_disk = files_on_disk()
    vanished = sorted(set(recorded()) - on_disk)

    assert not vanished, (
        "these files are in the duration record and are not in tests/ any "
        f"more: {vanished}. Re-record with "
        "`venv/bin/python tools/record_test_durations.py`.")


def test_the_floor_still_sits_in_a_gap_in_the_real_distribution():
    """The floor is only meaningful while nothing is sitting on it (L172).

    A threshold inside the dense part of a distribution turns the set it
    produces into noise: a small change in one file's cost carries it across,
    and the fast run's contents change for a reason nobody chose.

    Measured on 2026-08-21 there is a gap of nearly 5x: 17.3% of the run is the
    smallest expensive file and 3.5% the largest ordinary one. This turns red
    when a file lands in that gap, which is the moment to re-measure and
    re-choose rather than to widen the band.
    """
    crowding = sorted(
        (name, f"{share:.1%}") for name, share in shares().items()
        if EXPENSIVE_SHARE * GAP_BELOW <= share <= EXPENSIVE_SHARE * GAP_ABOVE)

    assert not crowding, (
        f"these files are now close to the {EXPENSIVE_SHARE:.0%} floor: "
        f"{crowding}. The floor was chosen to sit in a gap so that no small "
        "change in cost moves a file in or out of the fast run; it no longer "
        "does. Re-measure with tools/record_test_durations.py and choose a new "
        "EXPENSIVE_SHARE from where the distribution actually is.")


def test_every_expensive_file_is_marked_slow():
    """Derived from the measurement, so a newly expensive file is covered the
    day it is recorded rather than the day somebody remembers this file."""
    unmarked = []
    for name in sorted(expensive()):
        source = (TESTS_DIR / name).read_text(encoding="utf-8")
        # Comment lines stripped: a guard that can be satisfied by prose ABOUT
        # the marker is indistinguishable from one that works (L103).
        code = "\n".join(
            line for line in source.splitlines()
            if not line.strip().startswith("#")
        )
        if SLOW not in code:
            unmarked.append(name)

    assert not unmarked, (
        f"These files are at or above {EXPENSIVE_SHARE:.0%} of the run but "
        f"carry no "
        f"{SLOW}, so the fast local run still pays for them: "
        + ", ".join(unmarked)
    )


def test_nothing_else_is_marked_slow():
    """The other direction, and it covers two different mistakes.

    A marker spreading to ordinary files turns the fast run into a run of almost
    nothing, which looks exactly like a fast suite. And a file marked slow that
    was never MEASURED is the older mistake this replaced: the marker then
    records somebody's impression rather than a reading, which is how a 3.9s
    file came to be skipped (#766).
    """
    allowed = expensive()
    measured = set(recorded())
    strays = []
    for path in sorted(TESTS_DIR.glob("test_*.py")):
        if path.name in allowed or path.name == Path(__file__).name:
            continue
        code = "\n".join(
            line for line in path.read_text(encoding="utf-8").splitlines()
            if not line.strip().startswith("#")
        )
        if SLOW in code:
            why = ("is not in the duration record at all"
                   if path.name not in measured
                   else f"is {shares()[path.name]:.1%} of the run")
            strays.append(f"{path.name} ({why})")

    assert not strays, (
        "These files are marked slow and are not the measured expensive ones, "
        "so the fast run is skipping more than it should: " + ", ".join(strays)
        + f". The floor is {EXPENSIVE_SHARE:.0%} of the run; record a file with "
        "`venv/bin/python tools/record_test_durations.py` rather than marking "
        "it by eye."
    )


def test_the_marker_is_registered():
    """`--strict-markers` is on, so an unregistered marker is an error rather
    than a silently unfiltered test."""
    assert 'slow' in PYPROJECT.read_text(encoding="utf-8"), \
        "the slow marker has to be declared in pyproject.toml or every run errors"


def _target(name: str) -> tuple[list[str], str]:
    """A make target's prerequisites, and its recipe as one string.

    Both halves matter since the full run was split in two (#430): the full
    target reaches the ordinary tests through a PREREQUISITE and the slow ones
    through its own recipe, so a check that read only one of those would be
    reading half the run.
    """
    makefile = MAKEFILE.read_text(encoding="utf-8")
    header = re.search(rf"^{re.escape(name)}:(.*)$", makefile, re.MULTILINE)
    assert header, f"there is no {name} target in the Makefile"

    recipe: list[str] = []
    for line in makefile[header.end():].splitlines()[1:]:
        if line.startswith("\t"):
            recipe.append(line.strip())
        elif not line.strip():
            continue
        else:
            break
    return header.group(1).split(), "\n".join(recipe)


def test_there_is_a_fast_target_and_it_is_not_the_gate():
    """The fast target exists and deselects the slow files."""
    _, fast = _target("test-python-fast")

    assert fast, "the fast target runs nothing at all"
    assert "not slow" in fast, "the fast target does not actually deselect anything"


def _marker_filters(recipe: str) -> list[str | None]:
    """The `-m` expression of each pytest command in a recipe, None if unfiltered.

    None is the interesting value: a command with no marker filter runs
    everything, which is how the full target covers both halves in one pass.
    """
    filters: list[str | None] = []
    for line in recipe.splitlines():
        if "pytest" not in line:
            continue
        # Only the part AFTER pytest. The command starts `python -m pytest`, so a
        # scan of the whole line reads Python's module flag as pytest's marker
        # filter and reports every full run as selecting "pytest".
        arguments = line.split("pytest", 1)[1]
        match = re.search(r'-m\s+("[^"]+"|\S+)', arguments)
        filters.append(match.group(1).strip('"') if match else None)
    return filters


def test_the_full_target_still_runs_the_slow_files():
    """The defect this exists to catch: nothing runs the expensive files locally.

    Asserted as "the full run reaches the slow files" rather than as "it does not
    deselect them", because the second is a proxy and passes happily for a full
    target that simply stopped running them (L63). It is satisfied either by one
    unfiltered pass or by a pass that selects the marker, so the shape of the run
    can change without this having to be rewritten to match it.
    """
    prerequisites, full = _target("test-python")
    filters = _marker_filters(full)

    assert filters, f"the full target runs no pytest command at all: {full}"
    reaches_them = any(f is None or f == "slow" for f in filters)
    assert reaches_them, (
        "the full local target no longer reaches the slow files, so the four "
        f"files that render real reels run nowhere but CI. Filters: {filters}, "
        f"prerequisites: {prerequisites}")


def test_the_full_target_still_runs_the_ordinary_tests_too():
    """The other half. However the run is split, both halves have to be in it."""
    prerequisites, full = _target("test-python")
    filters = _marker_filters(full)

    reaches_them = (any(f is None or "not slow" in (f or "") for f in filters)
                    or "test-python-fast" in prerequisites)
    assert reaches_them, (
        "the full local target reaches the slow files and nothing else, so the "
        f"1700 ordinary tests are skipped locally. Filters: {filters}, "
        f"prerequisites: {prerequisites}")
