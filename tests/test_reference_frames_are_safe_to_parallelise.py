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
