"""The reference-frame checks stay safe to run in parallel (#412).

Those four files are 586 of the macOS job's 780 seconds, all of it rendering
real reels through ffmpeg, so the job now runs them with `-n auto`. Locally four
workers took them from 495s to 221s.

That is only safe while each test keeps its outputs to itself. Every one of them
currently writes into pytest's `tmp_path`, which is unique per test, and reads
everything else. The day one of them writes to a fixed path instead, two workers
share it and the failure is a flaky pixel comparison that reproduces on nobody's
machine, which is among the worst kinds of failure to be handed.

So the precondition is asserted rather than assumed. This does not prove
parallel safety in general; it catches the specific way it would be lost here.
"""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"
REQUIREMENTS = REPO_ROOT / "requirements.txt"


def _reference_frame_step() -> str:
    """The step's COMMAND, with its comment lines removed.

    Stripping the comments is load bearing rather than tidy. The first version of
    this read the whole block, and the comment above the command explains the
    parallel flag by naming it, so removing the flag from the command left the
    guard green on the prose describing it (L103). Caught by deleting the flag
    and watching the test pass.
    """
    workflow = WORKFLOW.read_text(encoding="utf-8")
    parts = workflow.split("Run the reference-frame and legibility checks", 1)
    assert len(parts) == 2, "the reference-frame step has been renamed or removed"
    block = parts[1].split("\n\n", 1)[0]
    return "\n".join(
        line for line in block.splitlines() if not line.strip().startswith("#")
    )


def _reference_frame_files() -> set[str]:
    return set(re.findall(r"tests/(test_[a-z0-9_]+\.py)", _reference_frame_step()))


def _code(path: Path) -> str:
    """Source with comments stripped, so prose about a rule cannot satisfy it."""
    return "\n".join(
        line for line in path.read_text(encoding="utf-8").splitlines()
        if not line.strip().startswith("#")
    )


def test_the_step_still_runs_in_parallel():
    """If this stops being true the job is back to 13 minutes, quietly."""
    assert "-n auto" in _reference_frame_step(), (
        "the reference-frame step is no longer parallel, which puts about six "
        "minutes back on every pull request"
    )


def test_xdist_is_pinned():
    """`-n auto` is an error, not a slow run, if the plugin is not installed."""
    requirements = REQUIREMENTS.read_text(encoding="utf-8")
    assert re.search(r"^pytest-xdist==", requirements, re.MULTILINE), (
        "pytest-xdist has to be pinned in requirements.txt or the parallel step "
        "fails outright on a clean runner"
    )


def test_no_reference_frame_test_writes_to_a_fixed_path():
    """The precondition for running these concurrently.

    Two workers sharing one output file produce a flaky pixel comparison that
    reproduces nowhere. Every write in these files has to go through `tmp_path`.
    """
    offenders: list[str] = []
    for name in sorted(_reference_frame_files()):
        code = _code(TESTS_DIR / name)
        for match in re.finditer(
            r'(output_path|out_path|dest|destination)\s*=\s*(.+)', code
        ):
            target = match.group(2)
            looks_shared = (
                "tmp_path" not in target
                and "tmp" not in target.lower()
                and not target.strip().startswith(("out", "path", "dest", "str(out"))
            )
            if looks_shared and ("/" in target or '"' in target or "'" in target):
                offenders.append(f"{name}: {match.group(0).strip()[:90]}")

    assert not offenders, (
        "These look like writes to a path shared between tests, which is unsafe "
        "once the step runs in parallel:\n" + "\n".join(offenders)
    )


#: Everything that runs pytest, so a parallel flag cannot be added to one of them
#: without this file having an opinion about it.
PYTEST_CALLERS = (
    Path("Makefile"),
    Path(".github/workflows/swift.yml"),
    Path(".github/workflows/tests.yml"),
    Path("PostRollApp/build-install.sh"),
)


def _pytest_invocations(text: str) -> list[str]:
    """Every pytest command in a file, each flattened onto one line.

    Flattened because a YAML folded block writes one command over several lines,
    and the macOS job's is written that way: its flags sit on a line of their own
    with no `pytest` on it. A scan that read single lines would skip the very
    invocation it exists to check, which is the shape of guard that reports green
    while blind.

    A command ends at the first blank line or the next YAML key, which covers
    both a Makefile recipe line and a workflow step.
    """
    commands: list[str] = []
    for match in re.finditer(r"pytest\b", text):
        tail = text[match.start():]
        end = len(tail)
        for stop in re.finditer(r"\n\s*\n|\n\s*-?\s*name:|\n\w+:", tail):
            end = stop.start()
            break
        commands.append(" ".join(tail[:end].split()))
    return commands


def test_the_scan_reads_a_command_split_over_several_lines():
    """The scanner's own precondition, seen to work rather than assumed (L1).

    If this ever stops holding, the parallel-safety check below silently starts
    ignoring the one invocation in the repo that is written this way.
    """
    folded = (
        "      - name: Run the checks\n"
        "        run: >\n"
        "          pytest tests/test_golden_frames.py\n"
        "          -n auto -v -ra\n"
        "\n"
        "      - name: Something else\n"
    )
    commands = _pytest_invocations(folded)

    assert commands == ["pytest tests/test_golden_frames.py -n auto -v -ra"], commands


def test_nothing_runs_the_whole_suite_in_parallel():
    """The suite as a whole is NOT safe to parallelise, and that is measured.

    On 2026-08-13 `pytest tests/ -n auto` was run against a clean tree and failed
    on `test_media_design_fingerprint.py`, reporting that the reel_morph template
    had been redesigned. It had not. That file proves its own guards by writing a
    perturbed copy of real modules under `postroll/media/` into place and
    restoring them afterwards, so a worker hashing those same files while the
    perturbation is in place reads it and reports a redesign that never happened.

    Because the collision is on DISK it does not matter that workers are separate
    processes, and because it depends on timing it fails on nobody's machine
    twice the same way. Flake like that costs more than the six minutes parallel
    running saves, so `-n` stays scoped to files that have been shown to keep
    their writes to `tmp_path`: the four reference-frame files, whether they are
    named directly or selected by the slow marker.

    #497 fixes the fingerprint tests, and this test is what has to be revisited
    when it lands.
    """
    offenders: list[str] = []
    for relative in PYTEST_CALLERS:
        for command in _pytest_invocations(_code(REPO_ROOT / relative)):
            if "-n" not in command.split():
                continue
            scoped = "-m slow" in command or "tests/test_" in command
            if not scoped:
                offenders.append(f"{relative}: {command}")

    assert not offenders, (
        "These run pytest in parallel over a selection wider than the files "
        "proven safe for it, which buys six minutes and pays for it in flake "
        "that reproduces nowhere:\n" + "\n".join(offenders)
    )


def test_the_slow_files_are_the_ones_the_local_run_parallelises():
    """The local full run has to parallelise the expensive half, or the four
    files that are 8m15s of a 9m53s run are still serial and the change bought
    nothing."""
    parallel = [command for command in _pytest_invocations(_code(REPO_ROOT / "Makefile"))
                if "-n" in command.split()]

    assert parallel, (
        "no local target runs anything in parallel, so the full run is back to "
        "ten minutes")
    assert any("-m slow" in line for line in parallel), (
        f"the local parallel pass does not select the slow files: {parallel}")


def test_every_reference_frame_file_uses_tmp_path():
    """The positive form of the same property, so a file that stopped taking
    tmp_path at all is caught rather than passing for want of a match."""
    without = [
        name for name in sorted(_reference_frame_files())
        if "tmp_path" not in _code(TESTS_DIR / name)
    ]
    assert not without, (
        "These render reels but never ask for a per-test directory, so it is not "
        "clear where their output goes: " + ", ".join(without)
    )
