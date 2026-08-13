"""The reference-frame checks stay safe to run in parallel (#412).

Those four files are the whole of the macOS job's slow half, all of it rendering
real reels through ffmpeg, so the job runs them with `-n auto` and, since #507,
splits them across a matrix of runners as well: `-n auto` can only use the three
cores one runner has, and the four files are about seventeen minutes of CPU.

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

import pytest

from ci_workflow import reference_frame_files as _reference_frame_files
from ci_workflow import shards, step_command


REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"
REQUIREMENTS = REPO_ROOT / "requirements.txt"


def _code(path: Path) -> str:
    """Source with comments stripped, so prose about a rule cannot satisfy it."""
    return "\n".join(
        line for line in path.read_text(encoding="utf-8").splitlines()
        if not line.strip().startswith("#")
    )


def test_the_step_still_runs_in_parallel():
    """If this stops being true the job is back to 13 minutes, quietly.

    Still worth asserting alongside the matrix rather than instead of it: the
    two do different work. The matrix gives each shard its own three-core
    runner, and `-n auto` is what uses those three cores.
    """
    assert "-n auto" in step_command(), (
        "the reference-frame step is no longer parallel, which puts about six "
        "minutes back on every pull request"
    )


def test_the_files_are_still_found():
    """Everything below measures this set, so it must not quietly become empty.

    #507 moved the file names out of the pytest command and into the job's
    matrix. A scan left pointing at the command would find nothing and every
    check derived from it would pass having examined no file at all (L98).
    """
    assert len(_reference_frame_files()) >= 4, (
        f"only found {_reference_frame_files()} across the shards")


def test_the_shard_scan_refuses_a_job_it_cannot_read():
    """The derivation seen failing, rather than trusted (L1).

    A workflow whose shards this cannot parse has to raise, not return an empty
    list: an empty list is indistinguishable from a job that runs nothing, and
    it would make every check above pass.
    """
    unreadable = (
        "jobs:\n"
        "  reference-frames:\n"
        "    runs-on: macos-15\n"
        "    steps:\n"
        "      - name: Run them\n"
        "        run: pytest tests/test_golden_frames.py\n"
    )

    with pytest.raises(AssertionError, match="shards"):
        shards(unreadable)


def test_the_shard_scan_reads_a_matrix():
    """The positive half: the shape the workflow actually uses is parsed."""
    workflow = (
        "jobs:\n"
        "  reference-frames:\n"
        "    strategy:\n"
        "      matrix:\n"
        "        shard:\n"
        "          - name: first\n"
        "            files: tests/test_golden_frames.py\n"
        "          - name: second\n"
        "            files: tests/test_gallery_alignment.py tests/test_a.py\n"
        "    steps:\n"
        "      - run: pytest ${{ matrix.shard.files }}\n"
        "  another-job:\n"
        "    steps:\n"
        "      - run: pytest tests/test_not_a_shard.py\n"
    )

    assert shards(workflow) == [
        ("first", ["tests/test_golden_frames.py"]),
        ("second", ["tests/test_gallery_alignment.py", "tests/test_a.py"]),
    ]


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


def test_the_whole_suite_is_run_in_parallel():
    """The restriction this file used to enforce is lifted, and this is what
    replaced it (L65: a guard whose reason has gone must be reasoned about, not
    quietly deleted).

    Until #497 the suite could not be run wholly in parallel. `pytest tests/ -n
    auto` failed on `test_media_design_fingerprint.py`, which proved its own
    guards by writing a perturbed copy of a real module under `postroll/media/`
    into place and restoring it, so a worker hashing that same file
    mid-perturbation read the perturbation and reported a redesign that never
    happened. Those guards now perturb a copy in `tmp_path`, and
    `tests/conftest.py` fails any module that writes into the source tree at all,
    which is what keeps this true rather than anyone remembering it.

    Measured twice on 2026-08-13, both green: 1787 tests in 3m24s and 3m34s,
    against 9m53s serial.
    """
    local = _pytest_invocations(_code(REPO_ROOT / "Makefile"))
    full = [c for c in local if "-m" not in c.split()]

    assert full, (
        "no local target runs the whole suite unfiltered any more, so either the "
        f"run was split again or the full local run has stopped being full: {local}")
    assert all("-n" in c.split() for c in full), (
        "the full local run is serial again, which puts six minutes back on every "
        f"run: {full}")


def test_the_source_tree_guard_is_still_armed():
    """What makes parallel running safe, and why it cannot be a comment.

    A test that writes into the checkout breaks the suite in two ways: it makes
    parallel runs flake in a way that reproduces on nobody's machine, and a run
    that dies between the write and the restore leaves an edit in the working tree
    that nobody made. The guard is a fixture rather than a test, so this asserts it
    is present and applies to everything.
    """
    conftest = _code(REPO_ROOT / "tests" / "conftest.py")

    assert "autouse=True" in conftest and "_source_tree_is_read_only" in conftest, (
        "the guard that stops a test writing into postroll/ is gone, so the next "
        "one to do it will be found as a flaky parallel run instead")


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
