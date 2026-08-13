"""The fast local suite deselects the slow files and nothing else (#413).

The full Python suite takes 9m53s on this Mac, and 8m15s of that is four files
that render real reels through ffmpeg and read pixels back out. That is long
enough that it stopped being run locally at all on 2026-08-12, which is how a
break gets found after a push rather than before.

So there is a fast target that skips those four. Two things have to stay true or
it becomes a way of not running the tests:

* The slow set is DERIVED from the macOS job that already names those files, not
  kept as a second list beside it. A hand-kept registry checks only what it
  lists, so the file missing from it is exempt from the very check meant to catch
  it (L96), and this repo has already been bitten by exactly that in
  `test_ci_runs_the_font_dependent_checks.py`. Since #507 the names live in that
  job's matrix rather than in its pytest command, and the reading of it is shared
  with the other two guards in `ci_workflow.py` so the three cannot disagree
  about which files are the expensive ones.
* CI still runs everything. The fast target is for the loop between edits; it is
  not the gate.
"""

from __future__ import annotations

import re
from pathlib import Path


from ci_workflow import reference_frame_files as _reference_frame_files


REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
MAKEFILE = REPO_ROOT / "Makefile"
PYPROJECT = REPO_ROOT / "pyproject.toml"

#: The marker that takes a file out of the fast run.
SLOW = "pytest.mark.slow"


def test_the_workflow_still_names_the_expensive_files():
    """If this finds nothing, every check below is measuring an empty set."""
    files = _reference_frame_files()
    assert len(files) >= 4, f"only found {files} across the macOS job's shards"


def test_every_expensive_file_is_marked_slow():
    """Derived from the workflow, so a fifth expensive file added there is
    covered the day it lands rather than the day somebody remembers this file."""
    unmarked = []
    for name in sorted(_reference_frame_files()):
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
        "These files are in the reference-frame step, which is where the time "
        f"goes, but carry no {SLOW}, so the fast local run still pays for them: "
        + ", ".join(unmarked)
    )


def test_nothing_else_is_marked_slow():
    """The other direction. A marker spreading to ordinary files turns the fast
    run into a run of almost nothing, which looks exactly like a fast suite."""
    expensive = _reference_frame_files()
    strays = []
    for path in sorted(TESTS_DIR.glob("test_*.py")):
        if path.name in expensive or path.name == Path(__file__).name:
            continue
        code = "\n".join(
            line for line in path.read_text(encoding="utf-8").splitlines()
            if not line.strip().startswith("#")
        )
        if SLOW in code:
            strays.append(path.name)

    assert not strays, (
        "These files are marked slow but are not the expensive ones, so the fast "
        "run is skipping more than it should: " + ", ".join(strays)
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
