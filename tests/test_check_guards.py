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
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

#: This repository, so a sweep driven in a subprocess can import the tool.
REPO_ROOT = Path(__file__).resolve().parent.parent

from tools.check_guards import (
    Entry,
    Outcome,
    RegistryError,
    check_guards,
    classify_pytest,
    classify_swift,
    command_for,
    derived_data_path,
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
    """The registry as it is really laid out: a directory holding one file per
    entry, each file named for the entry inside it (#506)."""
    path.mkdir(parents=True, exist_ok=True)
    for raw in entries:
        (path / f"{raw['name']}.json").write_text(json.dumps(raw))
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
#
# One file per entry, globbed (#506). Every branch that adds a guard used to
# append to one shared JSON file, so five branches in a day meant five rebase
# conflicts in the same place, and every hand resolution was a chance to drop
# an entry, which would remove a guard proof with no test noticing.


def test_load_registry_reads_entries(tmp_path: Path):
    path = write_registry(tmp_path / "registry", [registry_dict()])
    entries = load_registry(path)
    assert len(entries) == 1
    assert entries[0].name == "note-ink"
    assert entries[0].find == "Color.warmMid"


def test_load_registry_reads_every_file_in_the_directory(tmp_path: Path):
    """A loader that reads some of the directory is indistinguishable from one
    that reads all of it: the entries it skipped are simply never proven."""
    path = write_registry(tmp_path / "registry", [
        registry_dict(),
        registry_dict(name="note-wraps", find="let wraps = true",
                      replace="let wraps = false"),
        registry_dict(name="note-shape", find="struct Note",
                      replace="struct Memo"),
    ])
    assert {e.name for e in load_registry(path)} == {
        "note-ink", "note-wraps", "note-shape"}


def test_load_registry_refuses_a_malformed_file(tmp_path: Path):
    """A half written entry must stop the run and name itself, never be
    skipped: a skipped entry reads exactly like a guard nobody registered."""
    path = write_registry(tmp_path / "registry", [registry_dict()])
    (path / "half-written.json").write_text('{"name": "half-written",')
    with pytest.raises(RegistryError, match="half-written.json"):
        load_registry(path)


def test_load_registry_refuses_a_file_holding_the_old_whole_registry_shape(
        tmp_path: Path):
    """One file, one entry. A pasted `{"entries": [...]}` has no required
    fields at its top level, so it must fail rather than load as nothing."""
    path = write_registry(tmp_path / "registry", [registry_dict()])
    (path / "legacy.json").write_text(json.dumps({"entries": [registry_dict()]}))
    with pytest.raises(RegistryError, match="legacy.json"):
        load_registry(path)


def test_load_registry_refuses_two_files_claiming_one_name(tmp_path: Path):
    """Names have to stay unique across files, or `--only` and every message
    naming a guard become ambiguous."""
    path = write_registry(tmp_path / "registry", [registry_dict()])
    (path / "note-ink-again.json").write_text(json.dumps(registry_dict()))
    with pytest.raises(RegistryError, match="note-ink"):
        load_registry(path)


def test_load_registry_refuses_a_file_that_is_not_a_json_entry(tmp_path: Path):
    """A stray `.json.bak` or `.jsonc` beside the entries would be silently
    globbed past, which is an entry quietly missing from every sweep (L100).

    The message has to be the one about the file not belonging, because a
    stray file that merely fails the required-fields check later would make
    this pass while the skip it exists to catch is wide open."""
    path = write_registry(tmp_path / "registry", [registry_dict()])
    (path / "note-wraps.json.bak").write_text("{}")
    with pytest.raises(RegistryError, match="is not an entry file") as raised:
        load_registry(path)
    assert "note-wraps.json.bak" in str(raised.value)


def test_load_registry_allows_the_readme_beside_the_entries(tmp_path: Path):
    """The prose explaining the mechanism lives in the directory too."""
    path = write_registry(tmp_path / "registry", [registry_dict()])
    (path / "README.md").write_text("how this works\n")
    assert len(load_registry(path)) == 1


def test_load_registry_refuses_a_directory_that_is_not_there(tmp_path: Path):
    """A missing registry is not an empty one: it must say so rather than
    report zero guards to check (L98)."""
    with pytest.raises(RegistryError, match="does not exist"):
        load_registry(tmp_path / "nowhere")


def test_load_registry_refuses_a_missing_field(tmp_path: Path):
    broken = registry_dict()
    del broken["breaks"]
    path = write_registry(tmp_path / "registry", [broken])
    with pytest.raises(RegistryError, match="breaks"):
        load_registry(path)


def test_load_registry_refuses_a_mutation_that_changes_nothing(tmp_path: Path):
    """find == replace is a mutation check that checks nothing, which is the
    exact defect this tool exists to catch (L1)."""
    path = write_registry(tmp_path / "registry",
                          [registry_dict(replace="Color.warmMid")])
    with pytest.raises(RegistryError, match="changes nothing"):
        load_registry(path)


def test_load_registry_refuses_an_unrecognised_test_spec(tmp_path: Path):
    path = write_registry(tmp_path / "registry",
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


def test_a_pytest_spec_runs_through_the_repos_venv_when_there_is_one(repo: Path):
    venv = repo / "venv" / "bin"
    venv.mkdir(parents=True, exist_ok=True)
    (venv / "python").write_text("#!/bin/sh\n")

    cmd = command_for(entry(test="tests/test_note.py::test_ink"), repo)

    assert cmd[0] == str(venv / "python"), (
        "this project's pytest and its dependencies live in the venv, so a "
        "checkout that has one has to be run through it")
    assert "pytest" in cmd
    assert "tests/test_note.py::test_ink" in cmd


def with_shared_cache(repo: Path, path: str = "/tmp/some-cache") -> Path:
    """Give a throwaway repo the shared build-cache definition the real one has."""
    script = repo / "PostRollApp" / "derived-data-path.sh"
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_text('export POSTROLL_DERIVED_DATA="' + path + '"\n')
    return repo


def test_a_swift_run_reuses_the_projects_build_cache(repo: Path):
    """One warm cache across the sweep, rather than a full build per entry (#621).

    Every entry perturbs one file, so a shared cache means one file and its
    dependents recompile instead of the whole app. Without it xcodebuild picks
    its own location, which starts empty and is never the one `make build` has
    already filled.
    """
    with_shared_cache(repo, "/tmp/some-cache")

    cmd = command_for(entry(), repo)

    assert "-derivedDataPath" in cmd, (
        "the sweep builds into whatever location xcodebuild picks for itself, "
        "so it shares nothing with the project's own cache and pays a full "
        "build for every entry")
    assert cmd[cmd.index("-derivedDataPath") + 1] == "/tmp/some-cache"


def test_the_build_cache_is_read_from_the_one_shell_definition(repo: Path):
    """Read, not spelled again here (L41).

    The Makefile and build-install.sh both source that script for the same
    value. A copy in this tool would be a second spelling of one location,
    which is how a second cache quietly starts filling.
    """
    with_shared_cache(repo, "/tmp/moved-somewhere-else")

    cmd = command_for(entry(), repo)

    assert cmd[cmd.index("-derivedDataPath") + 1] == "/tmp/moved-somewhere-else", (
        "the tool did not follow the shell definition, so it is carrying its "
        "own idea of where the cache lives")


def test_the_real_definition_keeps_the_cache_out_of_the_synced_checkout():
    """The property that actually matters, asserted against the real script.

    The checkout is under ~/Documents, which iCloud syncs: a cache in there is
    uploaded, counted against Dan's storage and conflict-copied. Asserted as
    "outside the checkout" rather than as the literal path, so moving it
    somewhere else that is also safe passes (L103).
    """
    path = derived_data_path(REPO_ROOT)

    assert path is not None, (
        "the real repository cannot read its own shared build-cache "
        "definition, so every guard entry pays a full build")
    assert not Path(path).resolve().is_relative_to(REPO_ROOT), (
        f"the build cache resolves to {path}, which is inside the "
        "iCloud-synced checkout")


def test_a_checkout_without_the_shared_definition_says_the_sweep_will_pay_for_it(
        repo: Path, tmp_path: Path):
    """The failure path, which must be loud rather than merely slower (#621).

    A missing definition cannot stop the sweep: it still proves every guard,
    just at the old cost. What it must not do is go quiet, because a sweep
    paying a full build per entry looks exactly like one reusing a cache until
    somebody times it.
    """
    assert not (repo / "PostRollApp" / "derived-data-path.sh").exists()

    assert derived_data_path(repo) is None
    assert "-derivedDataPath" not in command_for(entry(), repo)

    registry = write_registry(tmp_path / "registry", [registry_dict()])
    lines: list[str] = []
    check_guards(repo, registry, a_runner(65, SWIFT_RED), log=lines.append)

    assert any("full" in line and "build" in line for line in lines), (
        "nothing in the log says the sweep is paying a whole build per entry, "
        "so the cost is invisible. Log was:\n" + "\n".join(lines))


def test_a_checkout_with_no_venv_uses_the_interpreter_it_is_running_under(repo: Path):
    """The rule, not the path. This asserted `endswith("venv/bin/python")`,
    which is true only on a machine that has one: CI checks out without a venv,
    so every Python guard reported "the runner failed: no such file" and the
    whole job could never pass (#541).
    """
    assert not (repo / "venv").exists()

    cmd = command_for(entry(test="tests/test_note.py::test_ink"), repo)

    assert cmd[0] == sys.executable


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
    registry = write_registry(tmp_path / "registry", [registry_dict()])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(65, SWIFT_RED), log=lines.append)
    assert code == 0
    assert any("KILLED" in line for line in lines)


def test_a_surviving_mutation_fails_the_run_and_names_the_guard(repo: Path, tmp_path: Path):
    registry = write_registry(tmp_path / "registry", [registry_dict()])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(0, SWIFT_GREEN), log=lines.append)
    assert code != 0
    assert any("SURVIVED" in line and "note-ink" in line for line in lines)


def test_an_empty_registry_is_a_failure_not_a_pass(repo: Path, tmp_path: Path):
    """Zero guards checked has to be its own non-success outcome (L98)."""
    registry = write_registry(tmp_path / "registry", [])
    code = check_guards(repo, registry, a_runner(65, SWIFT_RED), log=lambda _: None)
    assert code != 0


def test_only_runs_the_named_entry(repo: Path, tmp_path: Path):
    registry = write_registry(tmp_path / "registry", [
        registry_dict(),
        registry_dict(name="note-wraps", find="let wraps = true",
                      replace="let wraps = false"),
    ])
    runner = a_runner(65, SWIFT_RED)
    code = check_guards(repo, registry, runner, only="note-wraps", log=lambda _: None)
    assert code == 0
    assert len(runner.calls) == 1


def test_only_matching_nothing_is_a_failure(repo: Path, tmp_path: Path):
    registry = write_registry(tmp_path / "registry", [registry_dict()])
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
    write_registry(repo / "tests" / "fixtures" / "guard_mutations", entries)
    git(repo, "init", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "seed")
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    return repo


def scoped_registry(repo: Path) -> Path:
    return repo / "tests" / "fixtures" / "guard_mutations"


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
    record = scoped_registry(scoped_repo) / "other-guard.json"
    entry_json = json.loads(record.read_text())
    entry_json["breaks"] = "reworded"
    record.write_text(json.dumps(entry_json))
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
    write_registry(repo / "tests" / "fixtures" / "guard_mutations",
                   [registry_dict()])
    git(repo, "init", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "seed")
    runner = a_runner(65, SWIFT_RED)
    lines: list[str] = []
    code = check_guards(repo, repo / "tests" / "fixtures" / "guard_mutations",
                        runner, changed_only=True, log=lines.append)
    assert code != 0
    assert runner.calls == []
    assert any("base" in line for line in lines)


# ── #547: an interrupted sweep must not leave the perturbation applied ────────
#
# Hit live on 2026-08-13: a full sweep was killed to free the machine and left
# ProgramPDFBakery.swift holding `first(where: { _ in false })`, which compiles,
# reads plausibly, and makes the bake find no event. The try/finally already in
# run_entry covers an exception and a ctrl-C, because both unwind the stack.
# SIGTERM does not: the default handler terminates the process outright, so the
# finally never runs and the broken line stays on disk.


def _interruptible_repo(tmp_path: Path) -> tuple[Path, Path, Path]:
    """A repo whose guard test blocks, so the sweep can be signalled while the
    perturbation is applied."""
    repo = tmp_path / "slowrepo"
    (repo / "Sources").mkdir(parents=True)
    (repo / "tests").mkdir(parents=True)
    source = repo / "Sources" / "Note.swift"
    source.write_text(SOURCE)
    # Long enough that the signal always lands mid-run, and bounded so a stray
    # copy cannot outlive the suite.
    (repo / "tests" / "test_slow.py").write_text(
        "import time\n\n\ndef test_slow():\n    time.sleep(45)\n"
    )
    git(repo, "init", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "commit", "-m", "seed")
    registry = write_registry(
        repo / "registry",
        [registry_dict(test="tests/test_slow.py::test_slow")],
    )
    return repo, source, registry


def _sweep_in_a_subprocess(repo: Path, registry: Path) -> subprocess.Popen:
    """The sweep in a process of its own, so a real signal can be sent to it."""
    driver = (
        "import sys\n"
        f"sys.path.insert(0, {str(REPO_ROOT)!r})\n"
        "from pathlib import Path\n"
        "from tools.check_guards import check_guards, real_runner\n"
        f"raise SystemExit(check_guards(Path({str(repo)!r}), "
        f"Path({str(registry)!r}), real_runner))\n"
    )
    return subprocess.Popen(
        [sys.executable, "-c", driver],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )


def _wait_for_perturbation(source: Path, proc: subprocess.Popen) -> None:
    for _ in range(600):  # up to 60s
        if "Color.cream" in source.read_text():
            return
        if proc.poll() is not None:
            raise AssertionError(
                "the sweep exited before it perturbed anything, so this test "
                f"proves nothing: {proc.communicate()[0][-2000:]}")
        time.sleep(0.1)
    raise AssertionError("the perturbation was never applied")


@pytest.mark.parametrize("signum,name", [
    (signal.SIGTERM, "SIGTERM"),
    (signal.SIGINT, "SIGINT"),
])
def test_an_interrupted_sweep_puts_the_source_file_back(tmp_path: Path,
                                                        signum, name):
    repo, source, registry = _interruptible_repo(tmp_path)
    proc = _sweep_in_a_subprocess(repo, registry)
    try:
        _wait_for_perturbation(source, proc)
        # The mutation really is on disk at this point, which is what makes the
        # restore below a claim about behaviour rather than about timing.
        assert "Color.warmMid" not in source.read_text()

        proc.send_signal(signum)
        output = proc.communicate(timeout=60)[0]
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate()

    assert source.read_text() == SOURCE, (
        f"{name} left the perturbation applied: {source.read_text()!r}")
    # Deliberately not just the filename: the sweep already prints "breaking
    # Sources/Note.swift" on its way in, so matching that would let this pass on
    # the announcement of the damage rather than on the report of the repair
    # (L103).
    assert "put Sources/Note.swift back" in output, (
        f"the restore happened silently, so nothing tells the operator the "
        f"tree was touched and put right: {output[-2000:]}")
    assert name in output, (
        f"the report does not say what interrupted it: {output[-2000:]}")


def test_a_restore_that_fails_is_reported_rather_than_swallowed():
    """The worst outcome this mechanism has: the tree is left holding broken
    code that compiles and reads plausibly.

    Reporting only what was successfully put back would make that case look
    exactly like the clean one, which is the failure the handler exists to
    prevent, moved one step along (L11).
    """
    from tools.check_guards import _PENDING, _restore_pending

    unwritable = Path("/nonexistent-directory-for-this-test/Note.swift")
    _PENDING[unwritable] = b"original"
    try:
        restored, failed = _restore_pending()
    finally:
        _PENDING.pop(unwritable, None)

    assert restored == []
    assert [p for p, _ in failed] == [unwritable], (
        "a restore that could not happen was not reported, so an interrupted "
        "sweep would exit looking clean while the file is still perturbed")
