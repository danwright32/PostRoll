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
    Result,
    WarmBuild,
    write_timings,
    build_lock,
    build_lock_path,
    check_guards,
    classify_pytest,
    classify_swift,
    command_for,
    derived_data_path,
    load_registry,
    silenced_functions,
    stand_down_helpers,
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

# A mutation that made the code TRAP rather than fail an assertion (#1186).
#
# Transcribed from the real run on 2026-09-01, #1164: the mutation crossed the
# ends of a ClosedRange and `best...worst` trapped. The xctest process dies, so
# xcodebuild prints a grand total of zero, and the verdict was indistinguishable
# from a test path naming nothing. The discriminator is in the transcript: a
# crash prints a `Test Case ... started.` line and then a trap, where a spec
# matching nothing prints no `Test Case` line at all.
SWIFT_CODE_TRAPPED = (
    "Test Suite 'Selected tests' started at 2026-09-01 11:02:03.123.\n"
    "Test Suite 'ThursdayCoverPickTests' started at 2026-09-01 11:02:03.124.\n"
    "Test Case '-[PostRollTests.ThursdayCoverPickTests testTheBandIsClamped]'"
    " started.\n"
    "PostRollApp/Sources/Services/CoverPick.swift:88: Fatal error: Range "
    "requires lowerBound <= upperBound\n"
    "Restarting after unexpected exit, crash, or test timeout in "
    "ThursdayCoverPickTests.testTheBandIsClamped(); summary will include totals "
    "from previous launches.\n"
    "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n"
    "** TEST FAILED **\n"
)

# The same crash, arriving before xcodebuild printed any total at all. That
# lands in the OTHER branch, the one that blames the build or the test path.
SWIFT_CODE_TRAPPED_NO_TOTAL = (
    "Test Suite 'Selected tests' started at 2026-09-01 11:02:03.123.\n"
    "Test Case '-[PostRollTests.ThursdayCoverPickTests testTheBandIsClamped]'"
    " started.\n"
    "PostRollApp/Sources/Services/CoverPick.swift:88: Fatal error: Range "
    "requires lowerBound <= upperBound\n"
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


def test_a_mutation_that_crashed_the_runner_is_not_reported_as_a_bad_test_path():
    """#1186: two causes had one message, and it named the wrong one.

    Measured 2026-09-01 on #1164. A mutation crossed the ends of a ClosedRange,
    `best...worst` trapped, the xctest process died, and xcodebuild printed
    `Executed 0 tests`. The verdict said the spec matched nothing, so the reader
    went to check a test path that was correct all along. Distinct causes get
    distinct messages (L11).
    """
    verdict = classify_swift(65, SWIFT_CODE_TRAPPED)

    assert verdict.outcome is Outcome.ERROR
    assert "crash" in verdict.detail.lower(), verdict.detail
    # The trap itself, quoted: it is the finding. A crash means the code under
    # test is not total, which is a defect in it rather than noise in the sweep.
    assert "Range requires lowerBound <= upperBound" in verdict.detail
    # And it must stop sending the reader to the test path.
    assert "matched nothing" not in verdict.detail, verdict.detail


def test_the_crash_verdict_names_the_test_that_was_running():
    """A sweep entry runs one test, but the transcript is the only place that
    says WHICH one died, and a reader reproducing this needs it."""
    detail = classify_swift(65, SWIFT_CODE_TRAPPED).detail
    assert "testTheBandIsClamped" in detail, detail


def test_a_crash_before_any_total_is_printed_is_still_reported_as_a_crash():
    """The other branch blames the build or a missing test, and a trap that
    arrives before xcodebuild prints a total lands there (L173: a remedy scoped
    to the flavour of failure that was observed is absent in the neighbour)."""
    verdict = classify_swift(65, SWIFT_CODE_TRAPPED_NO_TOTAL)

    assert verdict.outcome is Outcome.ERROR
    assert "crash" in verdict.detail.lower(), verdict.detail
    assert "Range requires lowerBound <= upperBound" in verdict.detail


def test_a_spec_that_really_matched_nothing_still_says_so():
    """The positive control for the pair. A transcript with no test case and no
    trap has to keep the message it had, or the new branch has simply moved the
    ambiguity rather than removing it (L159)."""
    verdict = classify_swift(0, SWIFT_NOTHING_RAN)

    assert verdict.outcome is Outcome.ERROR
    assert "matched nothing" in verdict.detail
    assert "crash" not in verdict.detail.lower(), verdict.detail


def test_a_red_run_whose_own_output_says_fatal_error_is_still_a_kill():
    """The words are ordinary content, not only a trap.

    A guard's test can assert ABOUT a fatal error, print one in a message, or
    carry it in its name, and a run that really executed and really failed is a
    KILL whatever its text says (L104: check the filter against what it has to
    preserve, not only what it has to catch).
    """
    output = (
        "Test Case '-[PostRollTests.CrashReportTests testFatalErrorIsQuoted]'"
        " started.\n"
        "CrashReportTests.swift:31: error: -[PostRollTests.CrashReportTests "
        "testFatalErrorIsQuoted] : XCTAssertTrue failed - the report drops "
        "\"Fatal error: Range requires lowerBound <= upperBound\"\n"
        "\t Executed 1 test, with 1 failure (0 unexpected) in 0.1 (0.1) seconds\n"
        "** TEST FAILED **\n"
    )

    assert classify_swift(65, output).outcome is Outcome.KILLED


def test_the_grand_total_line_is_the_one_that_counts():
    output = (
        "\t Executed 1 test, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\n"
        "\t Executed 3 tests, with 1 failure (0 unexpected) in 0.4 (0.4) seconds\n"
        "** TEST FAILED **\n"
    )
    assert classify_swift(65, output).outcome is Outcome.KILLED


def test_pytest_exit_codes_map_to_the_three_outcomes():
    assert classify_pytest(1, "1 failed in 0.4s").outcome is Outcome.KILLED
    assert classify_pytest(0, "1 passed in 0.4s").outcome is Outcome.SURVIVED
    # 5 is "no tests collected", 2 is an internal error: neither is a verdict.
    assert classify_pytest(5, "no tests ran").outcome is Outcome.ERROR
    assert classify_pytest(2, "INTERNALERROR").outcome is Outcome.ERROR


def test_a_test_that_skipped_is_not_a_guard_that_survived():
    """A skip exits 0, and 0 was read as the guard staying green (#665).

    That verdict is an accusation: SURVIVED says the guard is not protecting the
    code and needs rewriting. A guard whose test needs an external the runner
    does not have (ffmpeg, on the sweep's own runner) is fine, and gets sent
    back to be rewritten anyway, while the thing actually missing goes unnamed.
    Measured on a real run: the clip reel's legibility guard was reported
    SURVIVED on a runner with no ffmpeg, having never executed.
    """
    verdict = classify_pytest(0, "1 skipped in 0.42s")

    assert verdict.outcome is Outcome.ERROR
    assert "skip" in verdict.detail.lower(), verdict.detail


def test_a_run_that_both_passed_and_skipped_is_still_a_survival():
    # A parametrised guard where one case is skipped and another really ran and
    # stayed green. Something DID execute against the broken code and did not
    # notice, which is exactly what SURVIVED means.
    verdict = classify_pytest(0, "1 passed, 1 skipped in 0.42s")

    assert verdict.outcome is Outcome.SURVIVED


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
    "    private func matcher(_ line: String) -> Bool { line.contains(\"x\") }\n"
    "    func testInk() { XCTAssertTrue(matcher(\"x\")) }\n"
    "    func testWraps() { XCTAssertTrue(true) }\n"
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
    (repo / "Sources" / "Wraps.swift").write_text("let wraps = true\n")
    (repo / "PostRollApp" / "Tests" / "NoteTests.swift").write_text(GUARD_TEST_SOURCE)
    (repo / "tests" / "test_other.py").write_text("def test_other():\n    pass\n")
    entries = [
        registry_dict(),
        # Shares NoteTests.swift with note-ink but protects a file of its own,
        # so "one test function changed" has a sibling it must not drag along.
        registry_dict(name="note-wraps", file="Sources/Wraps.swift",
                      find="let wraps = true", replace="let wraps = false",
                      test="PostRollTests/NoteTests/testWraps"),
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


def run_changed_all(repo: Path, runner) -> tuple[int, list[str]]:
    """Every entry, so the progress counter has something to count."""
    lines: list[str] = []
    code = check_guards(repo, scoped_registry(repo), runner, log=lines.append)
    return code, lines


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


def test_changed_mode_selects_every_entry_when_shared_test_code_changed(scoped_repo: Path):
    """A change OUTSIDE every test function selects them all (#634).

    This is the half that keeps the narrowing honest. A guard's behaviour lives
    as much in the matcher it calls as in the function that asserts on it, and
    editing a shared helper leaves every test function in the file byte for byte
    identical. Selecting only the functions that changed would skip exactly the
    entries that just changed meaning."""
    (scoped_repo / "PostRollApp" / "Tests" / "NoteTests.swift").write_text(
        GUARD_TEST_SOURCE + "// tightened\n")
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "touch guard")
    runner = a_runner(65, SWIFT_RED)
    code, _ = run_changed(scoped_repo, runner)
    assert code == 0
    assert len(runner.calls) == 2, "both entries in that file have to re-prove themselves"


def test_changed_mode_selects_only_the_guard_whose_own_test_changed(scoped_repo: Path):
    """Editing one guard re-proves that guard, not its neighbours (#634).

    BannerLegibilityTests holds about forty entries, so a one line change to one
    of them used to re-prove all forty at roughly 12 to 22 seconds each. An
    expensive habit is a habit that gets skipped, which is what #426 narrowed
    this sweep for once already."""
    source = (scoped_repo / "PostRollApp" / "Tests" / "NoteTests.swift").read_text()
    (scoped_repo / "PostRollApp" / "Tests" / "NoteTests.swift").write_text(
        source.replace('func testInk() { XCTAssertTrue(matcher("x")) }',
                       'func testInk() { XCTAssertTrue(matcher("x")); XCTAssertTrue(true) }'))
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "tighten testInk")

    runner = a_runner(65, SWIFT_RED)
    code, _ = run_changed(scoped_repo, runner)

    assert code == 0
    assert len(runner.calls) == 1, (
        "editing one test function re-proved its neighbour too, which is the "
        "cost this is meant to remove")
    assert "testInk" in " ".join(runner.calls[0])


def test_changed_mode_selects_everything_when_it_cannot_read_the_test_file(
        scoped_repo: Path):
    """Unparseable is not unchanged (L11).

    If the functions cannot be located the tool knows nothing about which guard
    moved, and the safe answer is to run them all and say why. Silently
    narrowing to none would report a clean sweep over guards it never touched."""
    (scoped_repo / "PostRollApp" / "Tests" / "NoteTests.swift").write_text(
        "import XCTest\n"
        "final class NoteTests: XCTestCase {\n"
        "    func testInk() { if x { \n")   # never closes
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "half written")

    runner = a_runner(65, SWIFT_RED)
    _, lines = run_changed(scoped_repo, runner)

    assert len(runner.calls) == 2, "a file it cannot read must not narrow anything"
    assert any("could not" in line.lower() or "cannot" in line.lower()
               for line in lines), (
        "nothing said the file could not be read, so a sweep that gave up on "
        "narrowing looks exactly like one that narrowed correctly\n"
        + "\n".join(lines))


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
    # Outside every test function, so both entries in that file are selected.
    assert len(runner.calls) == 2


def test_changed_mode_says_what_it_skipped(scoped_repo: Path):
    (scoped_repo / "Sources" / "Note.swift").write_text(SOURCE + "// touched\n")
    git(scoped_repo, "add", "-A")
    git(scoped_repo, "commit", "-m", "touch note")
    _, lines = run_changed(scoped_repo, a_runner(65, SWIFT_RED))
    assert any("1 of 3" in line and "skipped" in line for line in lines), lines


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


# ── Saying it is alive, and not fighting another build (#641, #642) ───────────


def test_each_entry_reports_where_it_has_got_to(scoped_repo: Path):
    """A run that is working and one that has hung must look different (#641).

    Over one session this cost four "is it still going?" checks and one wrong
    reading, where a half finished sweep was taken for a finished one and the
    working tree was inspected mid perturbation."""
    runner = a_runner(65, SWIFT_RED)
    _, lines = run_changed_all(scoped_repo, runner)

    progress = [line for line in lines if " of " in line and "]" in line]
    assert len(progress) >= 2, (
        "no line says how far through the sweep is, so twenty minutes of work "
        "looks the same as a hang:\n" + "\n".join(lines))
    assert "[1 of" in progress[0], progress[0]
    assert any("s]" in line for line in progress), (
        "no line carries elapsed time, so a slow entry and a stuck one are the "
        "same thing to anybody watching")


def test_the_log_reaches_the_terminal_as_it_goes(scoped_repo: Path, capsys):
    """Buffered output arrives all at once at the end, which is the whole
    defect: the file stays empty for the entire run (#641)."""
    flushes = []

    class Recording:
        def write(self, text): return len(text)
        def flush(self): flushes.append(True)

    real = sys.stdout
    sys.stdout = Recording()
    try:
        check_guards(scoped_repo, scoped_registry(scoped_repo),
                     a_runner(65, SWIFT_RED), changed_only=False)
    finally:
        sys.stdout = real

    assert flushes, (
        "nothing flushed, so redirected output sits in a buffer until the run "
        "ends and an empty log file means nothing")


def test_the_build_lock_sits_beside_the_shared_cache(repo: Path):
    """One lock for every xcodebuild that shares the cache (#642).

    Derived from the same shell definition as the cache itself, not spelled a
    second time, because two spellings of one location is how a second lock
    quietly starts protecting nothing (L41)."""
    with_shared_cache(repo, "/tmp/some-cache")

    assert build_lock_path(repo) == "/tmp/some-cache.lock"


def test_a_checkout_with_no_shared_cache_takes_no_lock(repo: Path):
    """The failure path. Without a shared cache there is nothing to contend
    over, and inventing a lock path would be inventing a location nothing else
    honours."""
    assert build_lock_path(repo) is None


def test_two_runs_do_not_build_at_the_same_time(tmp_path: Path):
    """Proven by holding it, not by reading the code (L1).

    A lock nobody has ever seen block is indistinguishable from no lock."""
    lock = tmp_path / "cache.lock"
    order: list[str] = []

    with build_lock(str(lock), log=lambda _: None):
        order.append("first in")
        proc = subprocess.Popen(
            [sys.executable, "-c",
             "import fcntl,sys;"
             f"f=open({str(lock)!r},'w');"
             "fcntl.flock(f, fcntl.LOCK_EX);"
             "print('second in')"],
            stdout=subprocess.PIPE, text=True)
        time.sleep(0.4)
        assert proc.poll() is None, (
            "the second run got in while the first held the lock, so two "
            "xcodebuilds can write to one DerivedData at once")
        order.append("first out")

    assert proc.communicate(timeout=10)[0].strip() == "second in"
    assert order == ["first in", "first out"]


def test_a_run_that_waits_for_the_lock_says_so(tmp_path: Path):
    """Waiting silently is the hang that #641 is about, arriving by another
    route."""
    lock = tmp_path / "cache.lock"
    said: list[str] = []

    holder = subprocess.Popen(
        [sys.executable, "-c",
         "import fcntl,time;"
         f"f=open({str(lock)!r},'w');"
         "fcntl.flock(f, fcntl.LOCK_EX);"
         "time.sleep(1.0)"])
    time.sleep(0.3)
    try:
        with build_lock(str(lock), log=said.append):
            pass
    finally:
        holder.wait(timeout=10)

    assert any("wait" in line.lower() for line in said), (
        "a run held up by another build said nothing, so it looks stalled\n"
        + "\n".join(said))



# ── Splitting the sweep, so it fits inside the runner's cap ───────────────────
#
# The post-merge sweep proves every registered guard, and it stopped finishing:
# on 2026-08-19 it hit the workflow's 60 minute cap, which GitHub reports as
# CANCELLED. That reads like a superseded run rather than a failure, so ~280
# guards quietly stopped being re-proved with nothing saying so (L98, L11). The
# registry had more than doubled since the 60 minute cap was measured against
# 119 entries, which the workflow's own comment predicted would happen.
#
# So the sweep splits across runners. The thing that can go wrong with splitting
# is silent: a partition that drops an entry leaves every shard green and the
# guard unproven, which looks exactly like a clean sweep.


def costs_of(entries, swift_seconds=29.0, python_seconds=0.8):
    """A cost for each entry, so the deal under test is not measuring whatever
    the live record happens to hold today (L196, L2).

    Every Swift entry the same and every Python entry the same, because these
    tests are about the PARTITION rather than about the readings: the tests that
    exercise the readings themselves are in tests/test_guard_entry_costs.py.
    """
    from tools.guard_entry_costs import Costs

    seconds = {
        e.name: (swift_seconds if e.test.startswith("PostRollTests/")
                 else python_seconds)
        for e in entries
    }
    return Costs(seconds=seconds, estimated=frozenset())


def test_every_entry_lands_in_exactly_one_shard():
    """The property the whole split rests on.

    An off-by-one that skips an entry cannot be seen in any shard's output:
    each one reports what it ran, all of them pass, and the dropped guard is
    never mentioned by anything.
    """
    from tools.check_guards import shard_of

    names = [f"guard-{i}" for i in range(97)]
    entries = [entry(name=n) for n in names]
    for total in (1, 2, 3, 5, 8, 13):
        seen: list[str] = []
        for index in range(1, total + 1):
            seen += [e.name for e in shard_of(entries, index, total,
                                              costs_of(entries))]
        assert sorted(seen) == sorted(names), (
            f"the {total}-way split does not cover the registry exactly once"
        )


def test_the_split_balances_the_measured_cost():
    """Swift entries pay a build each; Python ones are under a second.

    A split that put every Swift entry in one shard would leave that shard as
    slow as the whole sweep was, which is the thing being fixed. Asserted in
    SECONDS since #1090, not in a count of expensive entries: the count was a
    proxy, and a proxy passes while the thing it stands for drifts (L63).
    """
    from tools.check_guards import shard_of
    from tools.guard_entry_costs import imbalance

    entries = ([entry(name=f"swift-{i}") for i in range(40)]
               + [entry(name=f"py-{i}", test=f"tests/test_x.py::test_{i}")
                  for i in range(40)])
    costs = costs_of(entries)
    shards = [[e.name for e in shard_of(entries, index, 4, costs)]
              for index in range(1, 5)]

    assert imbalance(shards, costs.seconds) < 1.02, (
        f"the shards are dealt {[round(sum(costs.seconds[n] for n in s)) for s in shards]} "
        "seconds apart, so one runner carries the sweep and the split buys "
        "little"
    )


def test_one_very_expensive_entry_is_dealt_on_its_own():
    """What a count could never get right.

    Six entries, one of them thirty times the rest. Balancing the count puts
    three and three, so one shard carries 30s and the other 2.5s; balancing the
    cost gives the expensive one a runner to itself.
    """
    from tools.check_guards import shard_of
    from tools.guard_entry_costs import Costs

    entries = ([entry(name="big")]
               + [entry(name=f"py-{i}", test=f"tests/test_x.py::test_{i}")
                  for i in range(5)])
    costs = Costs(seconds={"big": 30.0, **{f"py-{i}": 0.5 for i in range(5)}},
                  estimated=frozenset())

    heavy = [e.name for e in shard_of(entries, 1, 2, costs)]
    light = [e.name for e in shard_of(entries, 2, 2, costs)]
    assert sorted(heavy + light) == sorted(e.name for e in entries)
    assert ["big"] in (heavy, light), (
        "the expensive entry was dealt alongside cheap ones, so this is still "
        "balancing a count"
    )


def test_a_shard_that_would_be_empty_is_refused():
    """More shards than entries means a runner proving nothing.

    A green run that checked nothing is indistinguishable from one that checked
    everything (L98), so it is an error rather than a quiet success.
    """
    from tools.check_guards import shard_of

    with pytest.raises(ValueError):
        shard_of([entry(name="only-one")], 2, 2, costs_of([entry(name="only-one")]))


def test_a_shard_spec_outside_the_split_is_refused():
    from tools.check_guards import shard_of

    entries = [entry(name=f"g-{i}") for i in range(4)]
    for bad in ((0, 2), (3, 2), (1, 0)):
        with pytest.raises(ValueError):
            shard_of(entries, *bad, costs_of(entries))


def test_the_sweep_says_which_shard_it_ran_and_how_many_it_left(
        repo: Path, tmp_path: Path, monkeypatch):
    """A shard's output must not read like a whole sweep.

    Every other scoping in this tool says what it skipped, for the same reason:
    proving four guards says nothing about the other two hundred and seventy six.
    """
    from tools.check_guards import check_guards

    registry = write_registry(
        tmp_path / "registry",
        [registry_dict(name=f"g-{i}", test=f"tests/test_x.py::test_{i}")
         for i in range(4)])
    # A record this test owns, so what it asserts about the log is not decided
    # by whatever the live one happens to hold today (L196).
    costs = tmp_path / "costs.json"
    costs.write_text(json.dumps({
        "seconds": {f"g-{i}": 0.5 + i for i in range(4)},
        "measured": {f"g-{i}": {"run": "r", "scale": 1.0} for i in range(4)},
    }))
    monkeypatch.setattr("tools.guard_entry_costs.RECORD", costs)
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(1, "1 failed"),
                        shard=(1, 2), log=lines.append)
    text = "\n".join(lines)
    assert code == 0
    assert "shard 1 of 2" in text, text
    assert "2 of 4" in text, text
    # And what the deal was made OF, because an estimate and a reading deal
    # identically and a partition of guesses reads as one of readings (L11).
    assert "dealt by measured cost: 2 of 2 entries" in text, text


# ── A deadline that reports as a failure, not as a cancellation ───────────────


def test_a_sweep_past_its_deadline_fails_and_names_what_it_never_reached(
        repo: Path, tmp_path: Path):
    """The whole reason the timeout was invisible.

    A job killed by the runner's cap reports CANCELLED, which is what a
    superseded run also reports, so the sweep stopping is indistinguishable
    from a run somebody replaced. Stopping ourselves turns it into a failure
    that says how many guards went unproven.
    """
    from tools.check_guards import check_guards

    registry = write_registry(
        tmp_path / "registry",
        [registry_dict(name=f"g-{i}", test=f"tests/test_x.py::test_{i}")
         for i in range(6)])
    lines: list[str] = []
    # Zero seconds: the first entry is already past it, so nothing depends on
    # how fast this machine happens to be (L134).
    code = check_guards(repo, registry, a_runner(1, "1 failed"),
                        deadline_seconds=0, log=lines.append)
    text = "\n".join(lines)
    assert code == 1, "a sweep that ran out of time reported success"
    assert "deadline" in text.lower(), text
    assert "unproven" in text.lower() or "never reached" in text.lower(), text


# ── who a missed deadline actually blocks (#1086) ─────────────────────────────
#
# The `full` sweep must FAIL on any unreached entry: it is the only thing that
# re-proves the whole registry, so an entry it silently skipped is one nothing
# proves at all.
#
# The per-pull-request `changed` job is a different question, and it is the one
# #1086 is about. Measured over 2026-08-30 and 31 it was the sole thing holding
# FIVE separate merges, for 15 to 19 minutes each, with every other check green.
# Failing a wide diff there turns a slow job into a blocked merge, and #989's
# daily sweep re-proves everything within a day either way.
#
# So the deadline blocks only the entries this diff EDITED: the ones whose guard
# test file or whose own registry record changed. That is the case the job exists
# to catch, a guard edited into uselessness in the same change that edits it.
# An entry selected only because the guarded FILE moved is warned about and left
# to the daily sweep.


def test_an_unreached_entry_this_diff_edited_blocks(repo: Path, tmp_path: Path):
    """The case the job exists to catch."""
    from tools.check_guards import check_guards

    registry = write_registry(
        tmp_path / "registry",
        [registry_dict(name=f"g-{i}", test=f"tests/test_x.py::test_{i}")
         for i in range(6)])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(1, "1 failed"),
                        deadline_seconds=0, blocking={"g-0"},
                        log=lines.append)
    text = "\n".join(lines)
    assert code == 1, f"an entry this diff edited went unproven and merged: {text}"
    assert "g-0" in text, text


def test_the_guards_this_diff_edited_are_proved_first(repo: Path, tmp_path: Path):
    """#1280: which entries a deadline reaches was decided by the alphabet.

    Entries run in registry order, which is alphabetical, and the deadline cuts
    wherever it lands. So a guard the diff EDITED went unproven, and blocked the
    merge, purely because its name sorted late among entries the diff had merely
    touched. That is what failed #1274 with two edited guards unproven and forced
    the change to ship as two pull requests, which costs a whole second run of
    every other job.

    Proving the edited ones first makes that impossible: a deadline can then only
    ever leave NON-blocking entries unreached, which warns rather than failing,
    and the daily sweep re-proves those within a day. No coverage changes; only
    the order does.
    """
    from tools.check_guards import check_guards

    # `z-edited` sorts LAST of the seven, and the clock is injected so the
    # deadline falls after exactly one entry has been proved. A zero deadline
    # would stop before any of them and could not tell an order apart (L159).
    registry = write_registry(
        tmp_path / "registry",
        [registry_dict(name=f"a-{i}", test=f"tests/test_x.py::test_{i}")
         for i in range(6)]
        + [registry_dict(name="z-edited", test="tests/test_x.py::test_edited")])
    clock = [0.0]

    def runner(cmd: list[str], cwd: Path) -> tuple[int, str]:
        clock[0] += 1.0
        return 1, "1 failed"

    lines: list[str] = []
    code = check_guards(repo, registry, runner, deadline_seconds=1.0,
                        blocking={"z-edited"}, log=lines.append,
                        now=lambda: clock[0])

    text = "\n".join(lines)
    assert "[1 of 7" in text and "z-edited" in text.split("\n")[0], (
        "the guard this diff edited was not the first entry proved, so which "
        f"entries the deadline reaches is still decided by the alphabet: {text}")
    assert code == 0, (
        "the guard this diff edited was left unproven by the deadline, so the "
        f"merge is blocked by where its name sorts: {text}")
    assert "never reached" in text, (
        "the deadline did not fire at all in this fixture, so it proves "
        "nothing about which entries it reaches (L159)")


def test_proving_the_edited_ones_first_does_not_reorder_the_full_sweep(
        repo: Path, tmp_path: Path):
    """The sweep has no notion of an edited guard: every entry blocks there,
    because it is the only thing re-proving the whole registry.

    Reordering it would matter anyway. A shard runs its entries in registry
    order, the first Swift one pays the cold build, and the cost record carries
    that reading separately so it is not read as that entry's own cost. So the
    order is left exactly as it was wherever `blocking` is None.
    """
    from tools.check_guards import order_for_the_deadline

    entries = [registry_dict(name=n, test="tests/test_x.py::t")["name"]
               for n in ("a", "b", "c")]

    assert order_for_the_deadline(entries, None, key=lambda n: n) == entries


def test_the_order_within_each_group_is_left_alone():
    """Stable within the two groups, so a run's order is still predictable and
    a shard's first Swift entry does not move about between runs."""
    from tools.check_guards import order_for_the_deadline

    names = ["a", "b", "c", "d"]

    assert order_for_the_deadline(names, {"b", "d"}, key=lambda n: n) == [
        "b", "d", "a", "c"]


def test_an_unreached_entry_this_diff_only_touched_warns(repo: Path,
                                                         tmp_path: Path):
    """A wide diff must not become a blocked merge.

    The entries are still named, and the daily sweep re-proves them within a
    day, so this is a warning with a reader and a remedy rather than silence
    (L98, L126).
    """
    from tools.check_guards import check_guards

    registry = write_registry(
        tmp_path / "registry",
        [registry_dict(name=f"g-{i}", test=f"tests/test_x.py::test_{i}")
         for i in range(6)])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(1, "1 failed"),
                        deadline_seconds=0, blocking=set(),
                        log=lines.append)
    text = "\n".join(lines)
    assert code == 0, f"a wide diff was turned into a blocked merge: {text}"
    assert "g-0" in text, "the unreached entries are not named at all"
    assert "unproven" in text.lower() or "never reached" in text.lower(), text


def test_a_sweep_with_no_diff_still_blocks_on_every_unreached_entry(
        repo: Path, tmp_path: Path):
    """The full sweep's behaviour, unchanged.

    `blocking=None` means there is no diff to judge against, which is the daily
    sweep. Reversing #989's decision here would leave the one job that re-proves
    the WHOLE registry able to skip entries and go green (L98).
    """
    from tools.check_guards import check_guards

    registry = write_registry(
        tmp_path / "registry",
        [registry_dict(name=f"g-{i}", test=f"tests/test_x.py::test_{i}")
         for i in range(6)])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(1, "1 failed"),
                        deadline_seconds=0, blocking=None, log=lines.append)
    assert code == 1, "\n".join(lines)


def test_a_red_guard_still_fails_even_when_nothing_blocks(repo: Path,
                                                          tmp_path: Path):
    """A SURVIVED guard is a verdict about coverage, not about time.

    Without this, softening the deadline could soften the whole exit code and
    a guard that stayed green on broken code would merge (L53).
    """
    from tools.check_guards import check_guards

    registry = write_registry(
        tmp_path / "registry",
        [registry_dict(name="g-0", test="tests/test_x.py::test_0")])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(0, "1 passed"),
                        deadline_seconds=3600, blocking=set(),
                        log=lines.append)
    assert code == 1, "\n".join(lines)
    assert "SURVIVED" in "\n".join(lines)


def test_a_sweep_inside_its_deadline_is_unaffected(repo: Path, tmp_path: Path):
    """The control. A deadline that fired on ordinary runs would be turned off,
    and then it would be protecting nothing (L36)."""
    from tools.check_guards import check_guards

    registry = write_registry(
        tmp_path / "registry",
        [registry_dict(name="g-0", test="tests/test_x.py::test_0")])
    lines: list[str] = []
    code = check_guards(repo, registry, a_runner(1, "1 failed"),
                        deadline_seconds=3600, log=lines.append)
    assert code == 0, "\n".join(lines)
    assert "deadline" not in "\n".join(lines).lower()


# ── #931: an entry whose test the prover itself silences ──────────────────────
#
# Since #920 the prover holds `perturbation_lock` across each perturbation, and
# the suite's registry check stands down while that lock is held. An entry whose
# `test` names one of the standing-down checks can therefore never be proved:
# the prover breaks the code, the named test skips, and no failure is ever seen.
#
# Correction to the reason this was filed with. It says the entry is reported
# SURVIVED for ever. It is not: `classify_pytest` has refused a skip-only run
# since #665, so the sweep reports ERROR. That is worse in one way and better in
# another. Better, because SURVIVED is an accusation and ERROR is not. Worse,
# because the message ERROR carries blames a missing external ("whatever it
# needs, ffmpeg, the macOS fonts, is missing here"), which is nothing to do with
# what happened, so the reader is sent to install something (L11). Either way
# the guard is never proved and the sweep never says why.


#: A stand-down helper shaped like the real one, and a test that calls it.
#:
#: Written out rather than imported so the fixture states the shape being
#: detected. `test_the_real_stand_down_helper_is_recognised` below is what holds
#: the detection to the actual code, because a rule proved only against a shape
#: I chose is a rule about my own fixture (L48, L96).
SILENCED_TEST_MODULE = '''
import pytest

from tools import perturbation_lock


def refuse_if_a_prover_is_working():
    outcome, why = perturbation_lock.verdict(REPO_ROOT)
    if outcome is perturbation_lock.Verdict.CANNOT_JUDGE:
        pytest.skip(why)


def test_every_anchor_still_matches(entry):
    refuse_if_a_prover_is_working()
    assert entry.find in entry.file
'''

#: A third state reader, appended to a COPY of the lock module so the
#: derivation can be asked whether it would find one (#1165).
#:
#: Written as source rather than as a name in a list, because the question is
#: whether the rule reads a real function definition the way it reads the two
#: that exist.
THIRD_READER = '''


def blocked(repo_root: Path) -> bool:
    """Whether anything at all holds the lock. Added after the tuple was written."""
    return current(repo_root) is not None
'''


#: The same module reached one step further away, which is how a real test file
#: grows: the guard is called by a shared setup rather than by the test itself.
INDIRECTLY_SILENCED_MODULE = SILENCED_TEST_MODULE + '''

def a_shared_precondition():
    refuse_if_a_prover_is_working()


def test_through_a_helper(entry):
    a_shared_precondition()
    assert entry.find in entry.file
'''

#: Reads the very same lock and does NOT stand down: it injects a checkout and
#: asserts on the answer. This is `tests/test_perturbation_lock.py`, and it is
#: the named alternative, so refusing it would refuse the remedy along with the
#: defect (L104).
LOCK_POLICY_MODULE = '''
from tools.perturbation_lock import Verdict, verdict


def test_a_stale_lock_is_reported_as_stale(tmp_path):
    assert verdict(tmp_path)[0] is Verdict.STALE
'''


def _repo_with_test_module(tmp_path: Path, source: str,
                           name: str = "test_thing.py") -> Path:
    repo = tmp_path / "checkout"
    (repo / "tests").mkdir(parents=True)
    (repo / "tests" / name).write_text(source)
    return repo


def _registry_dir(repo: Path) -> Path:
    return repo / "tests" / "fixtures" / "guard_mutations"


def _register(repo: Path, **overrides) -> None:
    write_registry(_registry_dir(repo), [registry_dict(**overrides)])


def test_load_registry_refuses_an_entry_whose_test_the_prover_silences(tmp_path):
    """The whole issue. The prover holds the lock, the named test skips, and no
    failure can ever be seen, so the entry reports the same thing on every
    sweep for ever while looking like a registered guard."""
    repo = _repo_with_test_module(tmp_path, SILENCED_TEST_MODULE)
    _register(repo, file="tests/test_thing.py", find="a", replace="b",
              test="tests/test_thing.py::test_every_anchor_still_matches")

    with pytest.raises(RegistryError, match="stands down"):
        load_registry(_registry_dir(repo), repo_root=repo)


def test_the_refusal_names_the_alternative(tmp_path):
    """A refusal that does not say what to do instead sends somebody back to
    the same choice with no more information than they had (L111)."""
    repo = _repo_with_test_module(tmp_path, SILENCED_TEST_MODULE)
    _register(repo, file="tests/test_thing.py", find="a", replace="b",
              test="tests/test_thing.py::test_every_anchor_still_matches")

    with pytest.raises(RegistryError) as raised:
        load_registry(_registry_dir(repo), repo_root=repo)

    message = str(raised.value)
    assert "test_perturbation_lock" in message, message
    assert "inject" in message, message


def test_a_test_silenced_through_a_helper_is_refused_too(tmp_path):
    """A rule that reads only the test's own body is answered by moving the
    call one line away, which is where a shared precondition normally lives."""
    repo = _repo_with_test_module(tmp_path, INDIRECTLY_SILENCED_MODULE)
    _register(repo, file="tests/test_thing.py", find="a", replace="b",
              test="tests/test_thing.py::test_through_a_helper")

    with pytest.raises(RegistryError, match="stands down"):
        load_registry(_registry_dir(repo), repo_root=repo)


#: The recommended pattern itself: drive the helper with an injected checkout
#: and CATCH the skip, turning it into a value the test can assert on. Nothing
#: here can be silenced by a real prover, because the skip never escapes and the
#: root is not the real one.
CATCHES_THE_STAND_DOWN_MODULE = SILENCED_TEST_MODULE + '''

def _reaction(repo_root):
    try:
        refuse_if_a_prover_is_working(repo_root)
    except pytest.skip.Exception as skipped:
        return "stood down", str(skipped)
    return "proceeded", ""


def test_the_check_stands_down_for_a_working_prover(tmp_path):
    assert _reaction(tmp_path)[0] == "stood down"
'''


def test_a_test_that_catches_the_stand_down_is_allowed(tmp_path):
    """The pattern the refusal recommends, which is also a real registered
    entry: `a-lock-nobody-holds-is-loud` points at exactly this shape in
    tests/test_perturbation_lock.py.

    A rule that followed the call graph without noticing the catch would refuse
    it, and the message would then be recommending something it forbids.
    """
    repo = _repo_with_test_module(tmp_path, CATCHES_THE_STAND_DOWN_MODULE)
    _register(repo, file="tests/test_thing.py", find="a", replace="b",
              test=("tests/test_thing.py"
                    "::test_the_check_stands_down_for_a_working_prover"))

    assert len(load_registry(_registry_dir(repo), repo_root=repo)) == 1


def test_a_test_that_reads_the_lock_without_standing_down_is_allowed(tmp_path):
    """The named alternative must survive the rule. Refusing every test that
    mentions the lock would refuse the remedy along with the defect, and the
    remedy is the whole content of the message (L104)."""
    repo = _repo_with_test_module(tmp_path, LOCK_POLICY_MODULE)
    _register(repo, file="tests/test_thing.py", find="a", replace="b",
              test="tests/test_thing.py::test_a_stale_lock_is_reported_as_stale")

    assert len(load_registry(_registry_dir(repo), repo_root=repo)) == 1


def test_an_ordinary_python_entry_is_untouched(tmp_path):
    repo = _repo_with_test_module(
        tmp_path, "def test_plain():\n    assert True\n")
    _register(repo, file="tests/test_thing.py", find="a", replace="b",
              test="tests/test_thing.py::test_plain")

    assert len(load_registry(_registry_dir(repo), repo_root=repo)) == 1


def test_a_swift_entry_is_not_examined_for_this(tmp_path):
    """The lock stands down a Python check. A Swift spec cannot be silenced by
    it, and looking for a Python module named by a Swift spec would refuse
    every Swift entry there is."""
    repo = _repo_with_test_module(tmp_path, SILENCED_TEST_MODULE)
    _register(repo)  # the default entry is a PostRollTests spec

    assert len(load_registry(_registry_dir(repo), repo_root=repo)) == 1


def test_the_lock_state_readers_are_read_off_the_lock_module():
    """#1165: the list named two instances of the reason, not the reason.

    `LOCK_STATE_READERS` was `("verdict", "current")`. A RENAME was covered by
    the test below; an ADDITION was not. A third function reporting the lock's
    state would have been absent from the tuple, so a test standing down through
    it was invisible to the check written to find exactly that (L96, L362).

    It is derived now, and this is the pair of claims that derivation rests on:
    the two real readers are found, and the two functions that are not readers
    are not. Both directions, because a rule matching everything would treat
    `lock_path(tmp_path)` as a stand-down and refuse the very file this refusal
    recommends as the alternative (L104, L159).
    """
    from tools.check_guards import LOCK_STATE_READERS

    assert set(LOCK_STATE_READERS) == {"current", "verdict"}, (
        f"the derivation now finds {LOCK_STATE_READERS}. If a real state "
        f"reader was added to perturbation_lock, say so here. If this went "
        f"EMPTY, the derivation has stopped describing the module and every "
        f"stand-down is invisible while the scan reports a clean tree")
    assert "lock_path" not in LOCK_STATE_READERS, (
        "lock_path hands back a Path, which says WHERE the lock is rather than "
        "what it says, and reading it as a stand-down is the over-match this "
        "was narrowed to avoid")
    assert "held_for" not in LOCK_STATE_READERS, (
        "held_for ACQUIRES the lock. A test inside one is holding it, not "
        "standing down because of it")


def test_a_new_lock_state_reader_is_picked_up_without_an_edit(tmp_path):
    """The point of deriving it.

    A hand written tuple passes the test above forever while being blind to
    whatever was added after it, and that blindness is exactly what #1165 is
    about (L96). This asks the real derivation about a lock module that has
    grown a third reader, rather than reimplementing the rule beside it, which
    would only prove this test agrees with itself (L70, L107).
    """
    from tools.check_guards import _lock_state_readers

    real = (Path(__file__).resolve().parent.parent / "tools"
            / "perturbation_lock.py").read_text(encoding="utf-8")
    grown = tmp_path / "perturbation_lock.py"
    grown.write_text(real + THIRD_READER, encoding="utf-8")

    found = _lock_state_readers(grown)

    assert "blocked" in found, (
        "a function added to the lock module that reports its state is not "
        "picked up, so a test standing down through it would be invisible to "
        "the refusal written to catch exactly that")
    assert {"current", "verdict"} <= set(found), (
        "and the two that were there before must still be found, or this "
        "passes by having broken the thing it is checking")


def test_the_real_stand_down_helper_is_recognised():
    """What holds the rule to this repository rather than to the fixture above.

    A detector whose vocabulary comes only from examples I wrote covers the
    shapes I had in mind and is silently blind to the one in the code (L48,
    L96). This asserts the real helper, in the real file, is what the scan
    finds, so renaming it or changing how it stands down fails here rather than
    quietly disarming the refusal.
    """
    found = stand_down_helpers(REPO_ROOT / "tests")

    assert "refuse_if_a_prover_is_working" in found, sorted(found)


def test_the_lock_policy_tests_are_not_mistaken_for_stand_down_helpers():
    """The same scan, on the file it must NOT catch. `test_perturbation_lock.py`
    reads the lock harder than anything else here and is the alternative the
    refusal recommends."""
    found = stand_down_helpers(REPO_ROOT / "tests")
    policy = (REPO_ROOT / "tests" / "test_perturbation_lock.py").read_text()

    named_there = [name for name in found if f"def {name}(" in policy]
    assert not named_there, (
        f"{named_there} in test_perturbation_lock.py are being read as helpers "
        "that stand down, which would refuse the very alternative the message "
        "tells people to use")


def test_the_real_registry_check_cannot_be_registered(tmp_path):
    """The case #931 was filed about, end to end against this repository.

    Everything above either drives a fixture module I wrote or scans the real
    tests directory. Neither on its own proves the refusal fires on the entry
    somebody would actually write, because two checks over one subject can each
    pass while the path between them is broken (L178). This is that path: a real
    registry entry, naming a real standing-down check in a real file, refused.

    Registered in a temporary directory rather than in `tests/fixtures/`, so
    the entry that must be refused never sits in the tree where a sweep could
    pick it up (L2).
    """
    registry = write_registry(tmp_path / "guard_mutations", [registry_dict(
        name="cannot-be-proved",
        file="tests/fixtures/guard_mutations/README.md",
        find="registry", replace="registries",
        test=("tests/test_guard_mutation_registry.py"
              "::test_every_anchor_still_matches_its_file_exactly_once"),
    )])

    with pytest.raises(RegistryError, match="stands down") as raised:
        load_registry(registry, repo_root=REPO_ROOT)

    assert "test_perturbation_lock" in str(raised.value)


def test_the_registry_this_repository_ships_is_accepted():
    """The other direction, and the one that makes the check above mean
    something: 400-odd real entries, none of them refused.

    A refusal nothing passes is not a check, it is an outage, and this rule
    reads every registered entry's test module (L104).
    """
    assert len(load_registry(REPO_ROOT / "tests" / "fixtures" / "guard_mutations",
                             repo_root=REPO_ROOT)) >= 100


def test_a_module_that_could_not_be_read_is_not_remembered_as_silencing_nobody(tmp_path):
    """An unreadable module is a NON-ANSWER, and it must not be cached as one.

    The answers here are cached per module, because 413 entries name barely a
    hundred files between them. Caching the empty answer given for a module
    that could not be parsed would turn "could not read this" into "this
    silences nobody" for the rest of the process, and once the two share a
    representation nothing can tell them apart (L215).
    """
    repo = _repo_with_test_module(tmp_path, "def broken(:\n")
    module = repo / "tests" / "test_thing.py"

    assert silenced_functions(module, repo) == frozenset(), (
        "a module that cannot be parsed is not this check's question")

    module.write_text(SILENCED_TEST_MODULE)

    assert "test_every_anchor_still_matches" in silenced_functions(module, repo), (
        "the unreadable answer was cached, so a module that can now be read is "
        "still remembered as silencing nobody")


# ── The app is built ONCE, before the loop (#1096) ────────────────────────────
#
# The first Swift entry of each shard paid for the cold app build that every
# entry after it reused. Measured on run 33409212726, one reading per shard and
# always that one: 85.0, 90.4, 120.2, 126.6, 127.9 and 137.8 seconds against a
# Swift median of 24.0. #1090 set those readings aside rather than record them
# as the entries' cost, which is right and leaves a permanent gap: a shard runs
# its entries in registry order, so the same entries are first every time and
# are estimated from their kind's median indefinitely.
#
# Building once before the loop closes it. No entry carries the build, so every
# reading is the steady-state cost.


def swift_registry(tmp_path: Path, *names: str) -> Path:
    return write_registry(
        tmp_path / "registry",
        [registry_dict(name=name, test=f"PostRollTests/NoteTests/{name}")
         for name in names])


def test_the_app_is_built_once_before_any_entry_runs(repo: Path, tmp_path: Path):
    with_shared_cache(repo)
    runner = a_runner(65, SWIFT_RED)

    check_guards(repo, swift_registry(tmp_path, "one", "two"), runner,
                 log=lambda _: None)

    assert runner.calls, "nothing ran at all"
    first = runner.calls[0]
    assert "build-for-testing" in first, (
        "the first thing the sweep ran was an entry, so that entry paid for "
        f"the cold build every entry after it reuses. It ran: {first}")
    assert "-only-testing" not in " ".join(first), (
        "the warm build is scoped to one test, so it builds no more than the "
        "first entry would have")
    assert first[first.index("-derivedDataPath") + 1] == "/tmp/some-cache", (
        "the warm build does not fill the cache the entries read, so it warms "
        "nothing and every entry still pays")


def test_a_run_with_no_swift_entry_does_not_build_the_app(repo: Path,
                                                          tmp_path: Path):
    """The `changed` job on a Python-only diff. Building there would add a
    couple of minutes to the job every pull request waits on, to warm a cache
    nothing in the run reads."""
    with_shared_cache(repo)
    (repo / "tests").mkdir(exist_ok=True)
    (repo / "tests" / "test_note.py").write_text("def test_ink():\n    pass\n")
    registry = write_registry(tmp_path / "registry", [registry_dict(
        file="tests/test_note.py", find="pass", replace="return",
        test="tests/test_note.py::test_ink")])
    runner = a_runner(1, "1 failed in 0.4s")

    check_guards(repo, registry, runner, log=lambda _: None)

    assert not any("build-for-testing" in " ".join(call)
                   for call in runner.calls), (
        "a run with no Swift entry built the app anyway")


def test_a_failed_warm_build_is_loud_and_does_not_stop_the_run(repo: Path,
                                                               tmp_path: Path):
    """Loud, because every Swift entry after it will report ERROR for a reason
    that has nothing to do with the guard, and the one line that explains all of
    them is this one (L11). Not fatal, because the run still has verdicts to
    reach and a tool that dies preparing has proven nothing."""
    with_shared_cache(repo)
    calls: list[list[str]] = []

    def runner(cmd: list[str], cwd: Path) -> tuple[int, str]:
        calls.append(cmd)
        if "build-for-testing" in cmd:
            return 65, "Note.swift:2:17: error: cannot find 'Color' in scope\n"
        return 65, SWIFT_RED

    lines: list[str] = []
    check_guards(repo, swift_registry(tmp_path, "one"), runner,
                 log=lines.append)

    said = "\n".join(lines)
    assert "build" in said.lower() and "failed" in said.lower(), (
        f"nothing said the shared build failed. Log was:\n{said}")
    assert "cannot find 'Color' in scope" in said, (
        "the compiler's own reason is not in the log, so the reader has a "
        "failure with no cause")
    assert len(calls) > 1, "the run stopped at the failed build"


def test_the_warm_build_is_inside_the_deadlines_clock(repo: Path, tmp_path: Path):
    """A build outside the clock is time the deadline cannot see, and the
    deadline exists because the runner's own cap reports CANCELLED, which is
    indistinguishable from a superseded run (#1086).

    The clock is SET rather than waited on, so this asserts about the sweep
    rather than about how loaded the machine is, and it costs nothing (L290,
    L524). Sleeping for a real 5 seconds would be the same assertion, slower,
    and would flake on a busy runner.
    """
    with_shared_cache(repo)
    clock = [0.0]

    def runner(cmd: list[str], cwd: Path) -> tuple[int, str]:
        if "build-for-testing" in cmd:
            clock[0] += 5.0
        return 65, SWIFT_RED

    lines: list[str] = []
    check_guards(repo, swift_registry(tmp_path, "one", "two"), runner,
                 deadline_seconds=1.0, log=lines.append,
                 now=lambda: clock[0])

    said = "\n".join(lines)
    # Both entries unreached is what discriminates. A deadline started AFTER
    # the build is not yet passed when the loop makes its first check, so the
    # first entry runs and the log still says "deadline" further down: a test
    # asserting only that word passes without the fix (L159).
    assert "2 entries never reached" in said, (
        "the deadline was measured from after the warm build, so the build's "
        f"time is free of it. Log was:\n{said}")


# ── and the readings say so ──────────────────────────────────────────────────

def result_of(name: str, seconds: float, swift: bool = True) -> Result:
    return Result(entry(name=name,
                        test=(f"PostRollTests/NoteTests/{name}" if swift
                              else f"tests/test_{name}.py::test_it")),
                  Outcome.KILLED, "", seconds)


def test_every_entry_carries_a_cost_once_the_build_is_shared(tmp_path: Path,
                                                             repo: Path):
    """The gap this closes. With the build outside the loop no entry pays for
    it, so setting the first Swift one aside would now discard a real reading."""
    path = tmp_path / "timings.json"

    write_timings(path, [result_of("one", 24.0), result_of("two", 22.0)],
                  repo, warm=WarmBuild(seconds=118.0, ok=True))

    written = json.loads(path.read_text())
    assert written["seconds"] == {"one": 24.0, "two": 22.0}


def test_the_shared_builds_own_cost_is_still_recorded(tmp_path: Path,
                                                      repo: Path):
    """It is the only measurement anyone has of what the cold build costs, and
    shipping the fix must not destroy the evidence the diagnosis came from
    (L277)."""
    path = tmp_path / "timings.json"

    write_timings(path, [result_of("one", 24.0)], repo,
                  warm=WarmBuild(seconds=118.0, ok=True))

    cold = json.loads(path.read_text())["cold"]
    assert cold["seconds"] == 118.0
    assert "build" in cold["entry"], (
        f"the cold reading is filed under {cold['entry']!r}, which reads as a "
        "registry entry's cost rather than as the shared build's")


def test_without_a_shared_build_the_first_swift_entry_is_still_set_aside(
        tmp_path: Path, repo: Path):
    """The case that has not gone away: a checkout naming no cache builds per
    entry, and the first one still carries the cold build."""
    path = tmp_path / "timings.json"

    write_timings(path, [result_of("one", 121.0), result_of("two", 22.0)],
                  repo, warm=None)

    written = json.loads(path.read_text())
    assert written["seconds"] == {"two": 22.0}
    assert written["cold"] == {"entry": "one", "seconds": 121.0}


def test_a_failed_shared_build_does_not_record_a_cold_reading(tmp_path: Path,
                                                              repo: Path):
    """A build that failed took whatever time a broken build takes, and filing
    that as the cold build's cost puts a number nothing can tell from a real one
    into the record (L331)."""
    path = tmp_path / "timings.json"

    write_timings(path, [result_of("one", 24.0)], repo,
                  warm=WarmBuild(seconds=3.0, ok=False))

    assert json.loads(path.read_text())["cold"] is None


# ── an anchor survives reindentation (#1040) ─────────────────────────────────
#
# Several entries anchor on exact indented text from a workflow, so ordinary
# reformatting broke them and the error named the guard rather than the edit.
# Hit twice on 2026-08-30 in one change: nesting an xcodebuild call under a
# wrapper shifted its arguments two spaces, and `derived-data-actually-built-into`
# matched 0 places instead of 1, needing a hand re-anchor with no behaviour
# change.
#
# A guard that breaks on whitespace teaches people that a red guard means a
# stale registry rather than a real regression, which is the reading that
# eventually waves a genuine one through.

def test_an_anchor_is_found_after_the_block_is_indented():
    from tools.check_guards import anchor_span

    recorded = "  - name: Run it\n    run: xcodebuild -scheme X\n"
    reindented_file = "jobs:\n  outer:\n      - name: Run it\n        run: xcodebuild -scheme X\n"

    start, end = anchor_span(reindented_file, recorded)

    assert reindented_file[start:end].strip().startswith("- name: Run it")


def test_an_exact_match_wins_over_a_looser_one():
    """Elasticity costs uniqueness. Three anchors in this registry are unique
    only by their indentation, and matching loosely FIRST made all three
    ambiguous, so the loose match is reached only when the exact one finds
    nothing, which is precisely the reformatting case (L214)."""
    from tools.check_guards import anchor_span

    # Two places that differ only in indentation; the recorded one is exact.
    text = "  run: a\n" + "      run: a\n"

    start, end = anchor_span(text, "      run: a\n")

    assert text[start:end] == "      run: a\n"


def test_an_anchor_matching_several_places_exactly_is_not_retried_loosely():
    """Loosening a pattern that already matches too much can only match
    more, so the refusal has to stand (L11)."""
    from tools.check_guards import StaleAnchor, anchor_span

    with pytest.raises(StaleAnchor) as refusal:
        anchor_span("  run: a\n  run: a\n", "  run: a\n")

    assert "2 places" in str(refusal.value)
    assert "indentation" not in str(refusal.value), (
        "it blamed indentation for an anchor that matches too much exactly, "
        "which sends the reader to fix the wrong thing (L11)")


def test_only_the_leading_whitespace_is_elastic():
    """It must not start matching a DIFFERENT place. Everything after the first
    non-space character is literal, so two steps that differ in their body are
    still two steps (L100)."""
    from tools.check_guards import StaleAnchor, anchor_span

    with pytest.raises(StaleAnchor):
        anchor_span("    run: xcodebuild -scheme Y\n", "  run: xcodebuild -scheme X\n")


def test_two_matches_after_reindentation_are_still_refused():
    from tools.check_guards import StaleAnchor, anchor_span

    # Neither is exact, and both match once indentation is allowed to vary.
    twice = "    run: a\n" + "      run: a\n"

    with pytest.raises(StaleAnchor) as refusal:
        anchor_span(twice, "  run: a\n")
    assert "2 " in str(refusal.value)


def test_the_replacement_follows_the_files_own_indentation():
    """Elastic matching alone would fix the FINDING and break the WRITING: a
    replacement pasted at the recorded indentation into a reindented file
    produces YAML that does not parse, and the guard would then fail for a
    reason unrelated to what it checks."""
    from tools.check_guards import reindented

    out = reindented(replace="  run: a\n  run: b\n",
                     matched="      run: a\n      run: b\n",
                     find="  run: a\n  run: b\n")

    assert out == "      run: a\n      run: b\n"


def test_a_replacement_needs_no_shift_when_nothing_moved():
    from tools.check_guards import reindented

    assert reindented("  a\n", "  a\n", "  a\n") == "  a\n"


def test_an_outdented_file_shifts_the_replacement_back():
    from tools.check_guards import reindented

    assert reindented("      a\n", "  a\n", "      a\n") == "  a\n"


def test_tabs_refuse_the_shift_rather_than_guessing():
    """The shift is a count of characters, and mixing tabs with spaces makes
    that arithmetic meaningless. Every file in this registry indents with
    spaces, so this is a refusal to guess rather than a path anybody takes."""
    from tools.check_guards import reindented

    assert reindented("  a\n", "\t\ta\n", "  a\n") == "  a\n"


def test_a_blank_line_in_the_replacement_stays_blank():
    from tools.check_guards import reindented

    out = reindented("  a\n\n  b\n", "    a\n\n    b\n", "  a\n\n  b\n")

    assert out == "    a\n\n    b\n"
