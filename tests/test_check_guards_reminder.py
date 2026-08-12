"""The push-time reminder to run the mutation check (#422).

`make check-guards` only proves anything when somebody runs it, and the moment
that matters is a push that changes a guard test without touching the mutation
registry. A project-scoped hook watches for exactly that push and reminds,
advisory and never blocking, because the check itself mutates the working tree
and pays a Swift build per entry, so it cannot run inside the push.

These drive the real script over throwaway git repos via its real entry point
(stdin payload in, JSON out), never the production repo (L2). The hook fails
quiet like the other advisories: a broken reminder must add nothing, so the
failure modes asserted here are silence, not errors.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "tools" / "remind-check-guards.py"

GUARD_TEST = (
    "import XCTest\n"
    "final class NoteGuardTests: XCTestCase {\n"
    "    func testInk() {}\n"
    "}\n"
)

REGISTRY = {
    "entries": [
        {
            "name": "note-ink",
            "file": "Sources/Note.swift",
            "find": "Color.warmMid",
            "replace": "Color.cream",
            "test": "PostRollTests/NoteGuardTests/testInk",
            "breaks": "the note goes invisible",
        }
    ]
}


def git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.email=t@example.com", "-c", "user.name=t", *args],
        cwd=repo, check=True, capture_output=True,
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A repo shaped like this one: a registry, a guard test, a plain test."""
    repo = tmp_path / "repo"
    (repo / "tests" / "fixtures").mkdir(parents=True)
    (repo / "PostRollApp" / "Tests").mkdir(parents=True)
    (repo / "Sources").mkdir()
    (repo / "tests" / "fixtures" / "guard_mutations.json").write_text(
        json.dumps(REGISTRY))
    (repo / "PostRollApp" / "Tests" / "NoteGuardTests.swift").write_text(GUARD_TEST)
    (repo / "PostRollApp" / "Tests" / "PlainTests.swift").write_text(
        "import XCTest\nfinal class PlainTests: XCTestCase {}\n")
    (repo / "Sources" / "Note.swift").write_text("let color = Color.warmMid\n")
    git(repo, "init", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "seed")
    # The pushed range is measured against origin/main, so give the repo one.
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    return repo


def remind(repo: Path, command: str) -> str:
    """Run the hook the way Claude Code runs it and return its reminder text,
    empty when it stayed silent."""
    payload = json.dumps({"tool_input": {"command": command}, "cwd": str(repo)})
    completed = subprocess.run(
        ["python3", str(SCRIPT)], input=payload, cwd=repo,
        capture_output=True, text=True, timeout=30)
    assert completed.returncode == 0, completed.stderr
    if not completed.stdout.strip():
        return ""
    out = json.loads(completed.stdout)
    return out["hookSpecificOutput"]["additionalContext"]


def commit_change(repo: Path, path: str, text: str) -> None:
    (repo / path).write_text(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "change")


# ── The push it exists for ────────────────────────────────────────────────────


def test_a_guard_test_change_without_a_registry_change_reminds(repo: Path):
    commit_change(repo, "PostRollApp/Tests/NoteGuardTests.swift",
                  GUARD_TEST.replace("testInk() {}", "testInk() { XCTAssert(true) }"))
    note = remind(repo, "git push")
    assert "make check-guards" in note
    assert "NoteGuardTests.swift" in note


def test_a_new_source_scanning_test_reminds_even_when_unregistered(repo: Path):
    (repo / "PostRollApp" / "Tests" / "FreshScanTests.swift").write_text(
        "import XCTest\n"
        "final class FreshScanTests: XCTestCase {\n"
        "    let dir = URL(fileURLWithPath: #filePath)\n"
        "        .appendingPathComponent(\"Sources\")\n"
        "}\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "new scan test")
    note = remind(repo, "git push")
    assert "FreshScanTests.swift" in note


def test_uncommitted_guard_work_counts_when_the_push_chains_a_commit(repo: Path):
    (repo / "PostRollApp" / "Tests" / "NoteGuardTests.swift").write_text(
        GUARD_TEST + "// pending edit\n")
    assert remind(repo, "git add -A") == ""
    note = remind(repo, "git add -A; git commit -m x; git push")
    assert "NoteGuardTests.swift" in note


# ── The pushes it must stay silent on ─────────────────────────────────────────


def test_silent_when_the_registry_changed_in_the_same_push(repo: Path):
    commit_change(repo, "PostRollApp/Tests/NoteGuardTests.swift",
                  GUARD_TEST + "// changed\n")
    registry = json.loads(
        (repo / "tests" / "fixtures" / "guard_mutations.json").read_text())
    registry["entries"][0]["breaks"] = "updated"
    commit_change(repo, "tests/fixtures/guard_mutations.json",
                  json.dumps(registry))
    assert remind(repo, "git push") == ""


def test_silent_when_only_ordinary_files_changed(repo: Path):
    commit_change(repo, "PostRollApp/Tests/PlainTests.swift",
                  "import XCTest\nfinal class PlainTests: XCTestCase { func testA() {} }\n")
    commit_change(repo, "Sources/Note.swift", "let color = Color.warmMid // note\n")
    assert remind(repo, "git push") == ""


def test_silent_when_the_command_is_not_a_push(repo: Path):
    commit_change(repo, "PostRollApp/Tests/NoteGuardTests.swift",
                  GUARD_TEST + "// changed\n")
    assert remind(repo, "git status") == ""
    # Naming a push is not running one: substring matching would fire on this.
    assert remind(repo, 'echo "git push is blocked"') == ""


def test_silent_outside_a_repo_with_a_registry(tmp_path: Path):
    """Advisory hooks fail quiet: in a repo this does not apply to, or on a
    payload it cannot read, it adds nothing rather than nagging (by design,
    matching the other advisories; silence never means \"checked and clean\")."""
    other = tmp_path / "other"
    other.mkdir()
    git(other, "init", "-b", "main")
    (other / "a.txt").write_text("x\n")
    git(other, "add", "-A")
    git(other, "commit", "-m", "seed")
    payload = json.dumps({"tool_input": {"command": "git push"}, "cwd": str(other)})
    completed = subprocess.run(["python3", str(SCRIPT)], input=payload,
                               cwd=other, capture_output=True, text=True, timeout=30)
    assert completed.returncode == 0
    assert completed.stdout.strip() == ""

    completed = subprocess.run(["python3", str(SCRIPT)], input="not json",
                               cwd=other, capture_output=True, text=True, timeout=30)
    assert completed.returncode == 0
    assert completed.stdout.strip() == ""
