"""The mutation check over the named guard tests (#416).

On 2026-08-12 four newly written guards were green against code that had been
deliberately broken, and every one was caught only because someone broke the
code by hand and watched for red. This tool makes that a mechanism: a registry
records, per guard, a one line perturbation of the code it protects; the
checker applies it, runs only that guard, requires it to fail, and puts the
file back.

These tests drive the checker itself against a throwaway git repo and a fake
test runner, so nothing here ever invokes the real xcodebuild (L2). The fake
runner's idea of xcodebuild output is verified against a real run before any
registry entry is trusted (L52); see the live check recorded on #416.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from tools.check_guards import (
    Entry,
    Outcome,
    RegistryError,
    check_guards,
    classify_pytest,
    classify_swift,
    command_for,
    load_registry,
    run_entry,
)

# ── Fixtures: a real tiny git repo, so the dirty check and any recovery path
#    exercise real git rather than a stub of it ────────────────────────────────

SOURCE = (
    "struct Note {\n"
    "    let color = Color.warmMid\n"
    "    let wraps = true\n"
    "}\n"
)


def git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.email=test@example.com", "-c", "user.name=test", *args],
        cwd=repo, check=True, capture_output=True,
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    (repo / "Sources").mkdir(parents=True)
    (repo / "Sources" / "Note.swift").write_text(SOURCE)
    git(repo, "init")
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "seed")
    return repo


def entry(**overrides) -> Entry:
    fields = {
        "name": "note-ink",
        "file": "Sources/Note.swift",
        "find": "Color.warmMid",
        "replace": "Color.cream",
        "test": "PostRollTests/NoteTests/testInk",
        "breaks": "the note draws in its own background colour",
    }
    fields.update(overrides)
    return Entry(**fields)


def write_registry(path: Path, entries: list[dict]) -> Path:
    path.write_text(json.dumps({"entries": entries}))
    return path


def registry_dict(**overrides) -> dict:
    e = entry(**overrides)
    return {"name": e.name, "file": e.file, "find": e.find,
            "replace": e.replace, "test": e.test, "breaks": e.breaks}


# What the real tools print. The Executed line is the shape actually emitted by
# xcodebuild 16 and 26 ("Executed 1 test, with 1 failure (0 unexpected) in
# 0.482 (0.484) seconds"), confirmed against a live run before the registry
# went in.
SWIFT_RED = (
    "Test Suite 'NoteTests' failed at 2026-08-12 14:00:00.000.\n"
    "\t Executed 1 test, with 1 failure (0 unexpected) in 0.482 (0.484) seconds\n"
    "Test Suite 'All tests' failed at 2026-08-12 14:00:00.001.\n"
    "\t Executed 1 test, with 1 failure (0 unexpected) in 0.482 (0.486) seconds\n"
    "** TEST FAILED **\n"
)
SWIFT_GREEN = (
    "Test Suite 'All tests' passed at 2026-08-12 14:00:00.001.\n"
    "\t Executed 1 test, with 0 failures (0 unexpected) in 0.482 (0.486) seconds\n"
    "** TEST SUCCEEDED **\n"
)
SWIFT_NOTHING_RAN = (
    "Test Suite 'All tests' passed at 2026-08-12 14:00:00.001.\n"
    "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n"
    "** TEST SUCCEEDED **\n"
)
SWIFT_BUILD_BROKE = (
    "Note.swift:2:17: error: cannot find 'Color' in scope\n"
    "** TEST FAILED **\n"
)


def a_runner(returncode: int, output: str):
    """A runner that records what it was asked to do."""
    calls: list[list[str]] = []

    def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
        calls.append(cmd)
        return returncode, output

    run.calls = calls
    return run


# ── The real runner ───────────────────────────────────────────────────────────


def test_the_real_runner_forbids_bytecode_writes():
    """A pytest run against MUTATED source must not leave compiled bytecode
    behind: the mutation and the restore can land in the same clock second
    with the same file size (\"-0.9\" for \"-1.0\"), and Python's cache checks
    exactly those two stand-ins, so a cache written from the broken code
    outlives the restore and the suite fails on code no file contains (L40).
    Seen live on 2026-08-12: the crop anchor mutation poisoned the cache and
    five crop tests failed on a byte-clean tree."""
    from tools.check_guards import real_runner

    code, output = real_runner(
        [sys.executable, "-c",
         "import os; print(os.environ.get('PYTHONDONTWRITEBYTECODE', 'unset'))"],
        Path.cwd())
    assert code == 0
    assert output.strip() == "1"


# ── Loading the registry ──────────────────────────────────────────────────────


def test_load_registry_reads_entries(tmp_path: Path):
    path = write_registry(tmp_path / "r.json", [registry_dict()])
    entries = load_registry(path)
    assert len(entries) == 1
    assert entries[0].name == "note-ink"
    assert entries[0].find == "Color.warmMid"


def test_load_registry_refuses_a_missing_field(tmp_path: Path):
    broken = registry_dict()
    del broken["breaks"]
    path = write_registry(tmp_path / "r.json", [broken])
    with pytest.raises(RegistryError, match="breaks"):
        load_registry(path)


def test_load_registry_refuses_duplicate_names(tmp_path: Path):
    path = write_registry(tmp_path / "r.json", [registry_dict(), registry_dict()])
    with pytest.raises(RegistryError, match="note-ink"):
        load_registry(path)


def test_load_registry_refuses_a_mutation_that_changes_nothing(tmp_path: Path):
    """find == replace is a mutation check that checks nothing, which is the
    exact defect this tool exists to catch (L1)."""
    path = write_registry(tmp_path / "r.json",
                          [registry_dict(replace="Color.warmMid")])
    with pytest.raises(RegistryError, match="changes nothing"):
        load_registry(path)


def test_load_registry_refuses_an_unrecognised_test_spec(tmp_path: Path):
    path = write_registry(tmp_path / "r.json",
                          [registry_dict(test="SomethingElse/NoteTests/testInk")])
    with pytest.raises(RegistryError, match="SomethingElse"):
        load_registry(path)


# ── Building the run command ──────────────────────────────────────────────────


def test_a_swift_spec_builds_an_only_testing_xcodebuild(repo: Path):
    cmd = command_for(entry(), repo)
    assert "xcodebuild" in cmd[0]
    assert "-only-testing:PostRollTests/NoteTests/testInk" in cmd
    assert "PostRollTests" in cmd[cmd.index("-scheme") + 1]
    assert "test" in cmd


def test_a_pytest_spec_runs_through_the_venv(repo: Path):
    cmd = command_for(entry(test="tests/test_note.py::test_ink"), repo)
    assert cmd[0].endswith("venv/bin/python")
    assert "pytest" in cmd
    assert "tests/test_note.py::test_ink" in cmd


# ── Reading the verdict ───────────────────────────────────────────────────────


def test_a_failing_swift_run_counts_as_killed():
    assert classify_swift(65, SWIFT_RED).outcome is Outcome.KILLED


def test_a_passing_swift_run_counts_as_survived():
    assert classify_swift(0, SWIFT_GREEN).outcome is Outcome.SURVIVED


def test_a_swift_run_that_executed_no_tests_is_an_error_not_a_kill():
    """A spec matching nothing exits green having proven nothing (L98)."""
    verdict = classify_swift(0, SWIFT_NOTHING_RAN)
    assert verdict.outcome is Outcome.ERROR
    assert "0 tests" in verdict.detail


def test_a_broken_build_is_an_error_not_a_kill():
    """A mutation that stops the build compiling kills every test trivially,
    which proves nothing about the guard. The run has to have happened."""
    verdict = classify_swift(65, SWIFT_BUILD_BROKE)
    assert verdict.outcome is Outcome.ERROR
    assert "never ran" in verdict.detail


def test_the_grand_total_line_is_the_one_that_counts():
    output = (
        "\t Executed 1 test, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\n"
        "\t Executed 3 tests, with 1 failure (0 unexpected) in 0.4 (0.4) seconds\n"
        "** TEST FAILED **\n"
    )
    assert classify_swift(65, output).outcome is Outcome.KILLED


def test_pytest_exit_codes_map_to_the_three_outcomes():
    assert classify_pytest(1).outcome is Outcome.KILLED
    assert classify_pytest(0).outcome is Outcome.SURVIVED
    # 5 is "no tests collected", 2 is an internal error: neither is a verdict.
    assert classify_pytest(5).outcome is Outcome.ERROR
    assert classify_pytest(2).outcome is Outcome.ERROR


# ── Running one entry: mutate, run, restore ───────────────────────────────────


def test_the_mutation_is_on_disk_while_the_test_runs(repo: Path):
    seen: list[str] = []

    def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
        seen.append((repo / "Sources" / "Note.swift").read_text())
        return 65, SWIFT_RED

    result = run_entry(entry(), repo, run)
    assert result.outcome is Outcome.KILLED
    assert "Color.cream" in seen[0]
    assert "Color.warmMid" not in seen[0]


def test_the_file_is_restored_byte_identical_after_the_run(repo: Path):
    run_entry(entry(), repo, a_runner(65, SWIFT_RED))
    assert (repo / "Sources" / "Note.swift").read_text() == SOURCE


def test_the_file_is_restored_even_when_the_runner_blows_up(repo: Path):
    def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
        raise RuntimeError("xcodebuild vanished")

    result = run_entry(entry(), repo, run)
    assert result.outcome is Outcome.ERROR
    assert "xcodebuild vanished" in result.detail
    assert (repo / "Sources" / "Note.swift").read_text() == SOURCE


def test_a_missing_anchor_is_a_stale_registry_error_and_nothing_runs(repo: Path):
    """The registry stays honest toward the code: an entry whose target moved
    fails rather than silently passing (#416)."""
    runner = a_runner(65, SWIFT_RED)
    result = run_entry(entry(find="Color.gone"), repo, runner)
    assert result.outcome is Outcome.ERROR
    assert "Color.gone" in result.detail
    assert runner.calls == []
    assert (repo / "Sources" / "Note.swift").read_text() == SOURCE


def test_an_ambiguous_anchor_is_refused(repo: Path):
    """Two matches means the recorded perturbation no longer names one place;
    mutating the first would be a guess (L100)."""
    runner = a_runner(65, SWIFT_RED)
    result = run_entry(entry(find="let "), repo, runner)
    assert result.outcome is Outcome.ERROR
    assert "2" in result.detail
    assert runner.calls == []


def test_a_dirty_target_file_is_refused_untouched(repo: Path):
    """Uncommitted work in the target file must never be put at risk by a tool
    whose whole job is overwriting and restoring that file (L5)."""
    dirty = SOURCE + "// half finished thought\n"
    (repo / "Sources" / "Note.swift").write_text(dirty)
    runner = a_runner(65, SWIFT_RED)
    result = run_entry(entry(), repo, runner)
    assert result.outcome is Outcome.ERROR
    assert "uncommitted" in result.detail
    assert runner.calls == []
    assert (repo / "Sources" / "Note.swift").read_text() == dirty


# ── The whole command ─────────────────────────────────────────────────────────


def test_every_mutation_killed_exits_zero(repo: Path, tmp_path: Path):
    registry = write_registry(tmp_path / "r.json", [registry_dict()])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(65, SWIFT_RED), log=lines.append)
    assert code == 0
    assert any("KILLED" in line for line in lines)


def test_a_surviving_mutation_fails_the_run_and_names_the_guard(repo: Path, tmp_path: Path):
    registry = write_registry(tmp_path / "r.json", [registry_dict()])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(0, SWIFT_GREEN), log=lines.append)
    assert code != 0
    assert any("SURVIVED" in line and "note-ink" in line for line in lines)


def test_an_empty_registry_is_a_failure_not_a_pass(repo: Path, tmp_path: Path):
    """Zero guards checked has to be its own non-success outcome (L98)."""
    registry = write_registry(tmp_path / "r.json", [])
    code = check_guards(repo, registry, a_runner(65, SWIFT_RED), log=lambda _: None)
    assert code != 0


def test_only_runs_the_named_entry(repo: Path, tmp_path: Path):
    registry = write_registry(tmp_path / "r.json", [
        registry_dict(),
        registry_dict(name="note-wraps", find="let wraps = true",
                      replace="let wraps = false"),
    ])
    runner = a_runner(65, SWIFT_RED)
    code = check_guards(repo, registry, runner, only="note-wraps", log=lambda _: None)
    assert code == 0
    assert len(runner.calls) == 1


def test_only_matching_nothing_is_a_failure(repo: Path, tmp_path: Path):
    registry = write_registry(tmp_path / "r.json", [registry_dict()])
    runner = a_runner(65, SWIFT_RED)
    code = check_guards(repo, registry, runner, only="no-such-guard",
                        log=lambda _: None)
    assert code != 0
    assert runner.calls == []


# ── The changed-only mode (#426) ──────────────────────────────────────────────
#
# A full sweep pays 17 app builds, so the moment a guard changes needs a run
# scoped to what the diff touches: the protected file, the guard's own test
# file, or the entry's registry record. Scoped means partial, and a partial
# run must say what it skipped rather than read as a full one (L98).

GUARD_TEST_SOURCE = (
    "import XCTest\n"
    "final class NoteTests: XCTestCase {\n"
    "    func testInk() {}\n"
    "}\n"
)


@pytest.fixture
def scoped_repo(tmp_path: Path) -> Path:
    """A repo shaped like this one, with its registry committed in-tree and a
    remote-tracking main to diff against."""
    repo = tmp_path / "scoped"
    (repo / "Sources").mkdir(parents=True)
    (repo / "PostRollApp" / "Tests").mkdir(parents=True)
    (repo / "tests" / "fixtures").mkdir(parents=True)
    (repo / "Sources" / "Note.swift").write_text(SOURCE)
    (repo / "Sources" / "Other.swift").write_text("let other = 1\n")
    (repo / "PostRollApp" / "Tests" / "NoteTests.swift").write_text(GUARD_TEST_SOURCE)
    (repo / "tests" / "test_other.py").write_text("def test_other():\n    pass\n")
    entries = [
        registry_dict(),
        registry_dict(name="other-guard", file="Sources/Other.swift",
                      find="let other = 1", replace="let other = 2",
                      test="tests/test_other.py::test_other"),
    ]
    write_registry(repo / "tests" / "fixtures" / "guard_mutations.json", entries)
    git(repo, "init", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "seed")
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    return repo


def scoped_registry(repo: Path) -> Path:
    return repo / "tests" / "fixtures" / "guard_mutations.json"


def run_changed(repo: Path, runner) -> tuple[int, list[str]]:
    lines: list[str] = []
    code = check_guards(repo, scoped_registry(repo), runner,
                        changed_only=True, log=lines.append)
    return code, lines


def test_changed_mode_selects_an_entry_whose_protected_file_changed(scoped_repo: Path):
    (scoped_repo / "Sources" / "Note.swift").write_text(SOURCE + "// touched\n")
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "touch note")
    runner = a_runner(65, SWIFT_RED)
    code, _ = run_changed(scoped_repo, runner)
    assert code == 0
    assert len(runner.calls) == 1
    assert any("NoteTests" in arg for arg in runner.calls[0])


def test_changed_mode_selects_an_entry_whose_swift_guard_test_changed(scoped_repo: Path):
    (scoped_repo / "PostRollApp" / "Tests" / "NoteTests.swift").write_text(
        GUARD_TEST_SOURCE + "// tightened\n")
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "touch guard")
    runner = a_runner(65, SWIFT_RED)
    code, _ = run_changed(scoped_repo, runner)
    assert code == 0
    assert len(runner.calls) == 1


def test_changed_mode_selects_a_pytest_entry_whose_test_file_changed(scoped_repo: Path):
    (scoped_repo / "tests" / "test_other.py").write_text(
        "def test_other():\n    assert True\n")
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "touch pytest guard")
    runner = a_runner(1, "1 failed")
    code, _ = run_changed(scoped_repo, runner)
    assert code == 0
    assert len(runner.calls) == 1
    assert "tests/test_other.py::test_other" in runner.calls[0]


def test_changed_mode_selects_an_edited_registry_entry_only(scoped_repo: Path):
    registry = json.loads(scoped_registry(scoped_repo).read_text())
    registry["entries"][1]["breaks"] = "reworded"
    scoped_registry(scoped_repo).write_text(json.dumps(registry))
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "edit one entry")
    runner = a_runner(1, "1 failed")
    code, _ = run_changed(scoped_repo, runner)
    assert code == 0
    assert len(runner.calls) == 1
    assert "tests/test_other.py::test_other" in runner.calls[0]


def test_changed_mode_counts_uncommitted_work(scoped_repo: Path):
    (scoped_repo / "PostRollApp" / "Tests" / "NoteTests.swift").write_text(
        GUARD_TEST_SOURCE + "// pending\n")
    runner = a_runner(65, SWIFT_RED)
    code, _ = run_changed(scoped_repo, runner)
    assert code == 0
    assert len(runner.calls) == 1


def test_changed_mode_says_what_it_skipped(scoped_repo: Path):
    (scoped_repo / "Sources" / "Note.swift").write_text(SOURCE + "// touched\n")
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "touch note")
    _, lines = run_changed(scoped_repo, a_runner(65, SWIFT_RED))
    assert any("1 of 2" in line and "skipped" in line for line in lines), lines


def test_changed_mode_with_nothing_affected_is_explicit(scoped_repo: Path):
    """Zero affected entries is a true negative, not a sweep: it must say
    nothing was verified rather than read as 38 guards passing (L98)."""
    runner = a_runner(65, SWIFT_RED)
    code, lines = run_changed(scoped_repo, runner)
    assert code == 0
    assert runner.calls == []
    assert any("nothing was verified" in line for line in lines), lines


def test_changed_mode_still_fails_on_a_surviving_mutation(scoped_repo: Path):
    (scoped_repo / "Sources" / "Note.swift").write_text(SOURCE + "// touched\n")
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "touch note")
    code, lines = run_changed(scoped_repo, a_runner(0, SWIFT_GREEN))
    assert code != 0
    assert any("SURVIVED" in line for line in lines)


def test_changed_mode_measures_against_main_not_the_pushed_branch(scoped_repo: Path):
    """Right after a push, the branch's own upstream already holds the change,
    and a scoped run based there reports nothing to verify while the work is
    still unmerged; main is the base that never under-selects."""
    git(scoped_repo, "remote", "add", "origin", str(scoped_repo))
    git(scoped_repo, "checkout", "-b", "feature")
    (scoped_repo / "Sources" / "Note.swift").write_text(SOURCE + "// touched\n")
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "touch note")
    git(scoped_repo, "update-ref", "refs/remotes/origin/feature", "HEAD")
    git(scoped_repo, "config", "branch.feature.remote", "origin")
    git(scoped_repo, "config", "branch.feature.merge", "refs/heads/feature")
    # Prove the upstream actually resolves, or this test is checking nothing.
    upstream = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "@{upstream}"],
        cwd=scoped_repo, capture_output=True, text=True)
    assert upstream.returncode == 0, upstream.stderr
    assert upstream.stdout.strip() == "origin/feature"
    runner = a_runner(65, SWIFT_RED)
    code, _ = run_changed(scoped_repo, runner)
    assert code == 0
    assert len(runner.calls) == 1


def test_a_failed_diff_is_none_never_an_empty_change_set(scoped_repo: Path):
    """A diff that errors must be distinguishable from a diff that found
    nothing, because reading a failure as no changes makes the scoped run
    silently skip every entry (L11)."""
    from tools.check_guards import changed_files

    assert changed_files(scoped_repo, "not-a-real-ref") is None
    assert changed_files(scoped_repo, "HEAD") == set()


def test_changed_mode_without_a_base_refuses(tmp_path: Path):
    """With nothing to diff against, a scoped run cannot know what changed,
    and guessing would silently skip real work; it refuses instead (L11)."""
    repo = tmp_path / "baseless"
    (repo / "Sources").mkdir(parents=True)
    (repo / "tests" / "fixtures").mkdir(parents=True)
    (repo / "Sources" / "Note.swift").write_text(SOURCE)
    write_registry(repo / "tests" / "fixtures" / "guard_mutations.json",
                   [registry_dict()])
    git(repo, "init", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "seed")
    runner = a_runner(65, SWIFT_RED)
    lines: list[str] = []
    code = check_guards(repo, repo / "tests" / "fixtures" / "guard_mutations.json",
                        runner, changed_only=True, log=lines.append)
    assert code != 0
    assert runner.calls == []
    assert any("base" in line for line in lines)
