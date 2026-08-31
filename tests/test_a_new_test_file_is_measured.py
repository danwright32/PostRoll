"""#1058: the branch that ADDS a test file is the one that measures it.

`test_the_record_still_covers_the_suite` bounds the WORST CASE of unmeasured
files against the smallest expensive file's share, so one or two new files slip
through and the debt lands on whoever happens to tip the total over.

That happened twice on 2026-08-30. #993 added `test_ci_builds_one_architecture.py`
and #991 added `test_no_dead_build_cache.py`, each passing alone; #1056 added a
third and went red for a reason belonging to the two merges before it. The
person who paid had to stop, measure three files they had not written, and
justify the numbers, and the remedy they were sent to (`make
record-test-durations`) re-reads the whole suite and re-derives every share,
which is #1038's subject and not something to do in the middle of unrelated
work.

So this asks the narrower question that has a clear owner: does THIS branch add
a test file the record has never seen. The aggregate check stays, because the
two catch different things and neither covers the other (L129): this one cannot
see the backlog that landed before it existed, and it cannot see a file that
arrives by any route other than a commit on a branch.

## Every uncertain answer is a SKIP that says why, never a pass

There is no git, there is no `origin/main`, the clone is shallow and has no
merge base with it. None of those is evidence that the branch added nothing, and
a check that reported success on them would be indistinguishable from one that
looked and found nothing wrong (L98). Each says which it was in its own words
(L11), and `-ra` in CI prints every one.

## Why committed changes and not the working tree

A file being written right now is not yet a claim about anything, and failing
the suite the moment a new test file appears would fire in the middle of every
piece of test-first work, which is when it is least useful and most likely to be
worked around. Reading the diff against the merge base means it fires once the
file is committed, which is still before the push that would otherwise carry it
into main unmeasured.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from file_durations import (
    added_test_files,
    recorded,
    unmeasured_additions,
)

REPO_ROOT = Path(__file__).resolve().parent.parent


# ── the decision, with its inputs handed to it ───────────────────────────────

def test_a_file_the_record_has_never_seen_is_named():
    assert unmeasured_additions(
        ["tests/test_brand_new.py"],
        recorded={"test_old.py": 1.0},
    ) == ["test_brand_new.py"]


def test_an_empty_record_names_every_addition_rather_than_none():
    """The direction that would be silent (L98).

    Written the other way round, as a truthiness test on the record, an empty
    or missing record would report every added file as already measured. That
    is the moment this check matters most and the moment it would say least,
    and nothing else here would notice: the assertion it makes is an ABSENCE,
    and an absence is exactly what a check reading nothing reports.
    """
    assert unmeasured_additions(["tests/test_x.py"], recorded={}) == ["test_x.py"]


def test_a_file_already_in_the_record_is_not_named():
    assert unmeasured_additions(
        ["tests/test_old.py"],
        recorded={"test_old.py": 1.0},
    ) == []


def test_a_file_recorded_as_costing_nothing_still_counts_as_measured():
    """0.0 is a reading. Absent is not, and the two must not collapse (L11).

    Several real guard files measure under 5ms and are recorded at 0.0, so
    treating a falsy value as unmeasured would demand they be re-measured
    forever and there would be no value that ever satisfied it.
    """
    assert unmeasured_additions(
        ["tests/test_tiny.py"],
        recorded={"test_tiny.py": 0.0},
    ) == []


def test_a_file_outside_tests_is_not_this_check_s_business():
    assert unmeasured_additions(
        ["tools/check_guards.py", "PostRollApp/Tests/Thing.swift"],
        recorded={},
    ) == []


def test_a_helper_module_in_tests_is_not_a_test_file():
    """The record holds `test_*.py`, which is what pytest collects. A fixture
    module beside them has no duration of its own and asking for one would be a
    demand nothing could satisfy."""
    assert unmeasured_additions(
        ["tests/conftest.py", "tests/file_durations.py", "tests/ci_workflow.py"],
        recorded={},
    ) == []


def test_several_additions_are_all_named_in_order():
    """The message has to name every one, or the person fixes them one per run."""
    assert unmeasured_additions(
        ["tests/test_b.py", "tests/test_a.py"],
        recorded={},
    ) == ["test_a.py", "test_b.py"]


# ── reading the additions out of git ─────────────────────────────────────────

def _git(repo: Path, *arguments: str) -> str:
    done = subprocess.run(
        ["git", "-C", str(repo), "-c", "user.email=t@example.com",
         "-c", "user.name=T", "-c", "commit.gpgsign=false", *arguments],
        capture_output=True, text=True, check=False)
    assert done.returncode == 0, f"git {arguments} failed: {done.stderr}"
    return done.stdout.strip()


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A real repository with a `main` and a branch off it.

    Real git rather than a stub, because what is under test is what a diff
    against a merge base reports, and a stub would only confirm what I already
    believe git does with one (L52).
    """
    here = tmp_path / "repo"
    (here / "tests").mkdir(parents=True)
    _git(here.parent, "init", "-q", "-b", "main", str(here))
    (here / "tests" / "test_already_here.py").write_text("def test_x(): pass\n")
    _git(here, "add", ".")
    _git(here, "commit", "-q", "-m", "base")
    _git(here, "branch", "-f", "origin-main-stand-in", "HEAD")
    return here


def test_a_test_file_added_on_the_branch_is_reported(repo: Path):
    _git(repo, "checkout", "-q", "-b", "work")
    (repo / "tests" / "test_added.py").write_text("def test_y(): pass\n")
    _git(repo, "add", ".")
    _git(repo, "commit", "-q", "-m", "add a test file")

    assert added_test_files(repo, base="origin-main-stand-in") == (
        "tests/test_added.py",)


def test_a_file_that_was_already_there_is_not_reported_as_added(repo: Path):
    """Modifying a file is not adding one, or every branch would owe a
    measurement for work it did not create."""
    _git(repo, "checkout", "-q", "-b", "work")
    (repo / "tests" / "test_already_here.py").write_text("def test_x(): pass\n# more\n")
    _git(repo, "add", ".")
    _git(repo, "commit", "-q", "-m", "edit an existing test file")

    assert added_test_files(repo, base="origin-main-stand-in") == ()


def test_a_branch_that_added_nothing_reports_nothing(repo: Path):
    _git(repo, "checkout", "-q", "-b", "work")
    assert added_test_files(repo, base="origin-main-stand-in") == ()


def test_an_uncommitted_file_is_not_reported(repo: Path):
    """Test-first work must not be interrupted by this. The file becomes this
    check's business when it is committed, which is still before the push."""
    _git(repo, "checkout", "-q", "-b", "work")
    (repo / "tests" / "test_being_written.py").write_text("def test_z(): pass\n")

    assert added_test_files(repo, base="origin-main-stand-in") == ()


def test_a_missing_base_ref_is_not_an_empty_answer(repo: Path):
    """`None`, never `()`. A branch point that cannot be found says nothing
    about what the branch added, and answering `()` would report a clean
    branch (L98, L119)."""
    assert added_test_files(repo, base="no-such-ref-anywhere") is None


def test_a_directory_that_is_not_a_repository_is_not_an_empty_answer(tmp_path):
    assert added_test_files(tmp_path, base="origin/main") is None


# ── the guard itself, against this repository ────────────────────────────────

def test_this_branch_measures_every_test_file_it_adds():
    added = added_test_files(REPO_ROOT)
    if added is None:
        pytest.skip(
            "the branch point against origin/main could not be found here, so "
            "which test files this branch adds is unknown. That is not the "
            "same as it adding none, and CI has the full history")

    missing = unmeasured_additions(added, recorded=recorded())

    assert not missing, (
        f"this branch adds {len(missing)} test file(s) the duration record has "
        f"never seen: {missing}. The record decides which files "
        "`make test-python-fast` skips, and a file absent from it is read as "
        "free by everything downstream, so measure them here rather than "
        "leaving the cost to whoever later tips the worst case over (#1058).\n"
        "Measure them beside files already in the record, in one run, so the "
        "readings can be scaled into the record's own run rather than mixed "
        "across runs (#1038, L224):\n"
        "  POSTROLL_REQUIRE_FFMPEG=1 venv/bin/python -m pytest "
        + " ".join(f"tests/{name}" for name in missing)
        + " tests/test_build_cache_location.py tests/test_manifest_contract.py "
          "-q -n auto --durations=0 --durations-min=0\n"
        "then add the summed seconds per file to "
        "tests/fixtures/test_file_durations.json.")
