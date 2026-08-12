"""The fast local suite deselects the slow files and nothing else (#413).

The full Python suite takes 9m53s on this Mac, and 8m15s of that is four files
that render real reels through ffmpeg and read pixels back out. That is long
enough that it stopped being run locally at all on 2026-08-12, which is how a
break gets found after a push rather than before.

So there is a fast target that skips those four. Two things have to stay true or
it becomes a way of not running the tests:

* The slow set is DERIVED from the workflow step that already names those files,
  not kept as a second list beside it. A hand-kept registry checks only what it
  lists, so the file missing from it is exempt from the very check meant to catch
  it (L96), and this repo has already been bitten by exactly that in
  `test_ci_runs_the_font_dependent_checks.py`.
* CI still runs everything. The fast target is for the loop between edits; it is
  not the gate.
"""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"
MAKEFILE = REPO_ROOT / "Makefile"
PYPROJECT = REPO_ROOT / "pyproject.toml"

#: The marker that takes a file out of the fast run.
SLOW = "pytest.mark.slow"


def _reference_frame_files() -> set[str]:
    """The test files the macOS job runs in its reference-frame step.

    Read out of the workflow rather than restated here, so the two cannot
    disagree about which files are the expensive ones.
    """
    workflow = WORKFLOW.read_text(encoding="utf-8")
    step = workflow.split("Run the reference-frame and legibility checks", 1)
    assert len(step) == 2, "the reference-frame step has been renamed or removed"
    return set(re.findall(r"tests/(test_[a-z0-9_]+\.py)", step[1]))


def test_the_workflow_still_names_the_expensive_files():
    """If this finds nothing, every check below is measuring an empty set."""
    files = _reference_frame_files()
    assert len(files) >= 4, f"only found {files} in the reference-frame step"


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


def test_there_is_a_fast_target_and_it_is_not_the_gate():
    """The fast target exists, deselects the slow files, and the full target
    still runs everything."""
    makefile = MAKEFILE.read_text(encoding="utf-8")

    assert "test-python-fast:" in makefile, "no fast target to run"
    fast = makefile.split("test-python-fast:", 1)[1].split("\n\n", 1)[0]
    assert "not slow" in fast, "the fast target does not actually deselect anything"

    full = makefile.split("test-python:", 1)[1].split("\n\n", 1)[0]
    assert "not slow" not in full, (
        "the FULL target is deselecting the slow files too, so nothing runs them "
        "locally at all"
    )
