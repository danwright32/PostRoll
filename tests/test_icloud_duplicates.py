"""#299: a numbered copy of a tracked file must stop the build.

This repo lives under `~/Documents`, which has iCloud Desktop and Documents
sync on, so iCloud resolves a sync race by writing a numbered copy beside the
original (`DesignStamp 2.swift`, `PostRoll 2.xcodeproj`). Six had accumulated
by 2026-08-10, byte identical to their originals, which is the dangerous shape:
a search matches the copy, an edit lands in it, and both the file and the build
look correct while the change does nothing.

`.gitignore` hides them from git, which is the opposite of reporting them. The
check here is the report: it reads the tracked file list from git rather than a
list of names kept by hand, so a file nobody thought to add is covered by the
same rule as the rest (LESSONS.md L96).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from tools.check_icloud_duplicates import (
    duplicate_of,
    scan,
    tracked_paths,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECKER = REPO_ROOT / "tools" / "check_icloud_duplicates.py"
PRE_PUSH = REPO_ROOT / ".githooks" / "pre-push"


# ── the shape iCloud actually writes ─────────────────────────────────────────


@pytest.mark.parametrize("copy,original", [
    ("DesignStamp 2.swift", "DesignStamp.swift"),
    ("PostRoll 2.xcodeproj", "PostRoll.xcodeproj"),
    ("project 3.pbxproj", "project.pbxproj"),
    # Two digit copies exist once a file has been resolved ten times, and the
    # .gitignore patterns (`*[ ][0-9]`) match one digit only, so a copy this
    # check missed would also be one git had started tracking.
    ("design_tokens 12.py", "design_tokens.py"),
    # No extension at all.
    ("Makefile 2", "Makefile"),
    # A compound extension: iCloud keeps the whole tail.
    ("bundle 2.tar.gz", "bundle.tar.gz"),
])
def test_the_numbered_shape_names_the_file_it_copied(copy, original):
    assert duplicate_of(copy) == original


@pytest.mark.parametrize("name", [
    "DesignStamp.swift",
    "generate_reel_morph.py",
    # A number that is part of the name rather than a copy marker.
    "ios26.swift",
    "Screenshot 2026-08-10 at 3.45.02 PM.png",
    # A trailing number with no space before it is the file's own name.
    "colorspace709.py",
])
def test_an_ordinary_name_is_not_a_copy(name):
    assert duplicate_of(name) is None


# ── the scan, against a real directory tree ──────────────────────────────────


def _tree(root: Path, files: list[str]) -> None:
    for rel in files:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x")


def test_a_copy_beside_a_tracked_file_is_reported(tmp_path):
    _tree(tmp_path, ["src/DesignStamp.swift", "src/DesignStamp 2.swift"])

    assert scan(tmp_path, tracked={"src/DesignStamp.swift"}) == ["src/DesignStamp 2.swift"]


def test_a_copied_directory_is_reported_once_not_every_file_inside_it(tmp_path):
    _tree(tmp_path, [
        "app/PostRoll.xcodeproj/project.pbxproj",
        "app/PostRoll 2.xcodeproj/project.pbxproj",
        "app/PostRoll 2.xcodeproj/xcshareddata/x.plist",
    ])

    assert scan(tmp_path, tracked={"app/PostRoll.xcodeproj/project.pbxproj"}) == [
        "app/PostRoll 2.xcodeproj"
    ]


def test_a_numbered_file_that_copies_nothing_tracked_is_left_alone(tmp_path):
    # The copy shape alone is not a defect. It is only one when it shadows a
    # file the project actually builds from.
    _tree(tmp_path, ["notes/Scratch 2.txt", "notes/kept.txt"])

    assert scan(tmp_path, tracked={"notes/kept.txt"}) == []


def test_a_tracked_file_whose_own_name_ends_in_a_number_is_not_reported(tmp_path):
    # Someone may legitimately commit "Take 2.wav" beside "Take.wav". It is
    # tracked, so it is the project's file and not iCloud's copy of one.
    _tree(tmp_path, ["audio/Take.wav", "audio/Take 2.wav"])

    assert scan(tmp_path, tracked={"audio/Take.wav", "audio/Take 2.wav"}) == []


def test_a_copy_is_only_a_copy_where_the_original_lives(tmp_path):
    # Compared by full path, not by name: iCloud writes the copy beside its
    # original, and matching on the basename alone would flag an unrelated file
    # in a directory the project does not track.
    _tree(tmp_path, ["src/DesignStamp.swift", "venv/lib/DesignStamp 2.swift"])

    assert scan(tmp_path, tracked={"src/DesignStamp.swift"}) == []


def test_the_git_directory_is_never_walked(tmp_path):
    # iCloud writes copies inside .git too. They are git's own business, they
    # are never read by a search or an edit, and walking that tree is the
    # slowest part of the scan.
    _tree(tmp_path, ["src/a.swift", ".git/objects/pack/pack 2.idx"])

    assert scan(tmp_path, tracked={"src/a.swift"}) == []


def test_directories_holding_nothing_tracked_are_not_walked(tmp_path):
    # The prune rule that keeps the scan fast. Derived from the tracked list
    # rather than a list of directory names kept here, so it cannot hide a
    # finding: a copy of a tracked file lives beside that file by definition,
    # and every directory holding one is on a tracked path.
    heavy = tmp_path / "venv" / "lib" / "python3.11"
    heavy.mkdir(parents=True)
    (heavy / "deep.py").write_text("x")
    _tree(tmp_path, ["src/a.swift", "src/a 2.swift"])

    walked: list[str] = []
    real_walk = os.walk

    def counting_walk(top, *a, **kw):
        for dirpath, dirnames, filenames in real_walk(top, *a, **kw):
            walked.append(dirpath)
            yield dirpath, dirnames, filenames

    scan(tmp_path, tracked={"src/a.swift"}, walk=counting_walk)

    assert not any("venv" in w for w in walked), walked


# ── the tracked list comes from git, and an empty one is not a pass ──────────


def test_the_tracked_list_is_read_from_this_repo():
    # Read through the same call the check uses, against the real repo, because
    # a stub can only confirm the assumption made when writing it (L52).
    tracked = tracked_paths(REPO_ROOT)

    assert "postroll/media/design_tokens.py" in tracked
    assert "PostRollApp/project.yml" in tracked
    assert len(tracked) > 100


def test_an_empty_tracked_list_is_an_error_rather_than_a_clean_run(tmp_path):
    # Finding nothing to check reads exactly like finding nothing wrong
    # (LESSONS.md L98), and an empty list is what a broken git call returns.
    _tree(tmp_path, ["src/a.swift", "src/a 2.swift"])

    with pytest.raises(ValueError):
        scan(tmp_path, tracked=set())


def test_the_checker_exits_non_zero_when_it_finds_a_copy(tmp_path):
    # The guard seen refusing, through the entry point the push hook runs
    # (LESSONS.md L1).
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    _tree(tmp_path, ["src/a.swift"])
    subprocess.run(["git", "add", "src/a.swift"], cwd=tmp_path, check=True)
    (tmp_path / "src" / "a 2.swift").write_text("x")

    result = subprocess.run([sys.executable, str(CHECKER), str(tmp_path)],
                            capture_output=True, text=True)

    assert result.returncode != 0
    assert "src/a 2.swift" in result.stdout + result.stderr


def test_the_checker_exits_zero_on_a_clean_tree(tmp_path):
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    _tree(tmp_path, ["src/a.swift"])
    subprocess.run(["git", "add", "src/a.swift"], cwd=tmp_path, check=True)

    result = subprocess.run([sys.executable, str(CHECKER), str(tmp_path)],
                            capture_output=True, text=True)

    assert result.returncode == 0, result.stdout + result.stderr


def test_a_repo_with_nothing_tracked_fails_rather_than_reporting_clean(tmp_path):
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)

    result = subprocess.run([sys.executable, str(CHECKER), str(tmp_path)],
                            capture_output=True, text=True)

    assert result.returncode != 0
    assert "tracked" in (result.stdout + result.stderr).lower()


# ── this repo, right now ─────────────────────────────────────────────────────


def test_this_working_tree_carries_no_numbered_copies():
    """The check doing its job. This is the assertion that goes red the next
    time iCloud writes a copy of a file the project builds from."""
    found = scan(REPO_ROOT, tracked=tracked_paths(REPO_ROOT))

    assert found == [], (
        "iCloud numbered copies of tracked files are in the working tree. "
        "Delete them (they shadow the real file in searches and edits): "
        + ", ".join(found)
    )


# ── the push gate ────────────────────────────────────────────────────────────


def test_the_pre_push_hook_runs_the_checker():
    # The test suite catches this only when someone runs it. The push hook is
    # what makes the gate fire where the style and test gates fire.
    assert PRE_PUSH.exists(), "no .githooks/pre-push"
    assert os.access(PRE_PUSH, os.X_OK), ".githooks/pre-push is not executable"
    assert "check_icloud_duplicates.py" in PRE_PUSH.read_text()


def test_the_pre_push_hook_refuses_a_tree_with_a_copy_in_it(tmp_path):
    # The hook seen refusing, run as git runs it.
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    _tree(tmp_path, ["src/a.swift"])
    subprocess.run(["git", "add", "src/a.swift"], cwd=tmp_path, check=True)
    (tmp_path / "src" / "a 2.swift").write_text("x")
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools" / "check_icloud_duplicates.py").write_bytes(
        CHECKER.read_bytes())

    result = subprocess.run(["bash", str(PRE_PUSH)], cwd=tmp_path,
                            capture_output=True, text=True, input="")

    assert result.returncode != 0
    assert "a 2.swift" in result.stdout + result.stderr


def test_the_pre_push_hook_can_be_overridden_out_loud(tmp_path):
    # Every other gate has a named override. Without one, the only way past a
    # false positive is deleting the check.
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    _tree(tmp_path, ["src/a.swift"])
    subprocess.run(["git", "add", "src/a.swift"], cwd=tmp_path, check=True)
    (tmp_path / "src" / "a 2.swift").write_text("x")
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools" / "check_icloud_duplicates.py").write_bytes(
        CHECKER.read_bytes())

    env = dict(os.environ, SKIP_ICLOUD_DUP_CHECK="1")
    result = subprocess.run(["bash", str(PRE_PUSH)], cwd=tmp_path, env=env,
                            capture_output=True, text=True, input="")

    assert result.returncode == 0, result.stdout + result.stderr
