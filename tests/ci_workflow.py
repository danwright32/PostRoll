"""Where the macOS job's reference-frame work is declared, read in one place.

Separate guards need to know which test files that job runs, and each one used
to work it out with its own regex over the workflow text:

* `test_ci_runs_the_font_dependent_checks.py` asserts the job RUNS every file
  carrying a macOS font marker.
* `test_reference_frames_are_safe_to_parallelise.py` asserts those files stay
  safe to run concurrently.

`test_fast_subset_stays_honest.py` was a third reader, deriving the SLOW marker
set from these files. It is not any more (#766): the matrix says which files need
the macOS system faces, which is a different property from being expensive, and
it derives its set from a measurement now.

Copies of one derivation are chances to spell it differently, and the
failure is silent in the worst way: a copy that matches nothing reports a clean
run over an empty set (L98), which is precisely what happened to the font guard
once already when it matched one remembered marker name. So the derivation lives
here, once, and every function below RAISES rather than returning an empty
answer, because "the shape of the workflow changed" and "there is nothing to
check" have to be different outcomes.

Read as text rather than parsed as YAML, for the reason `test_ci_gates.py`
gives: a YAML parser is not worth a runtime dependency for this.
"""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "swift.yml"

#: The job that renders the reels and reads pixels back out of them.
JOB = "reference-frames"

#: The step inside it that runs pytest.
STEP = "Run the reference-frame and legibility checks"

#: The matrix expression the step has to interpolate. Without it the shards are
#: decoration: the matrix would fan the job out and every copy would run the
#: same hardcoded command (L46, a value written and never read).
MATRIX_FILES = "matrix.shard.files"


def workflow_text() -> str:
    if not WORKFLOW.exists():
        raise AssertionError(
            f"{WORKFLOW} is missing, so nothing here can say what CI runs. "
            "That is a failure rather than a skip: a guard that cannot read "
            "its subject has measured nothing.")
    return WORKFLOW.read_text(encoding="utf-8")


def without_comments(text: str) -> str:
    """Whole-line comments removed.

    Load bearing rather than tidy: every setting in this workflow is explained
    by a comment above it that names the setting, so a guard reading the raw
    text can be satisfied by the prose describing a rule that has been deleted
    (L103).
    """
    return "\n".join(
        line for line in text.splitlines() if not line.strip().startswith("#")
    )


def job_block(text: str | None = None, name: str = JOB) -> str:
    """One job's body, so a claim about this job cannot be met by the other one.

    Ends at the next line indented by exactly two spaces, which is the next job
    header: everything inside a job is indented further.
    """
    settings = without_comments(workflow_text() if text is None else text)
    match = re.search(
        rf"^  {re.escape(name)}:[ \t]*$(.*?)(?=^  \S|\Z)", settings, re.M | re.S)
    if not match:
        raise AssertionError(
            f"there is no `{name}:` job in {WORKFLOW.name} any more, so every "
            "check derived from it is reading nothing. If the job was renamed, "
            "rename it here too rather than leaving the guards blind.")
    return match.group(1)


def shards(text: str | None = None) -> list[tuple[str, list[str]]]:
    """Each matrix shard of the reference-frame job: its name, and its files.

    The job is fanned out over a matrix because a standard macOS runner has
    three cores, so `-n auto` inside one job could only ever use three of them.
    That means the file names live in the matrix rather than in the pytest
    command, and a guard still scanning the command would find nothing.
    """
    block = job_block(text)
    entries = re.findall(
        r"^\s*-\s*name:\s*(\S+)\s*\n\s*files:\s*(.+)$", block, re.M)
    if not entries:
        raise AssertionError(
            f"no `- name:`/`files:` shards found in the {JOB} job, so every "
            "check that asks what CI runs is measuring an empty set. Either "
            "the matrix has gone or it is written in a shape this cannot read.")

    parsed: list[tuple[str, list[str]]] = []
    for name, files in entries:
        found = re.findall(r"tests/test_[a-z0-9_]+\.py", files)
        if not found:
            raise AssertionError(
                f"the {name!r} shard names no test files at all: {files!r}")
        parsed.append((name, found))
    return parsed


def reference_frame_files(text: str | None = None) -> set[str]:
    """Every test file the job runs, across all its shards, by bare name."""
    return {Path(path).name for _, files in shards(text) for path in files}


def files_in_more_than_one_shard(text: str | None = None) -> list[str]:
    """Files two shards would both run.

    A duplicate is not a correctness problem, it is a cost and a wall-clock
    one: the file is rendered twice, on two billed runners, and the shard
    balance the durations were measured for is silently wrong.
    """
    seen: list[str] = [Path(p).name for _, files in shards(text) for p in files]
    return sorted({name for name in seen if seen.count(name) > 1})


def step_command(text: str | None = None) -> str:
    """The reference-frame step's command, with its comment lines removed.

    Kept separate from the shard list on purpose: the shards say WHAT the job
    runs and this says HOW, and the two have to be checked against different
    things.
    """
    settings = workflow_text() if text is None else text
    parts = settings.split(STEP, 1)
    if len(parts) != 2:
        raise AssertionError(
            f"the step named {STEP!r} has been renamed or removed, so the "
            "checks derived from it are reading nothing")
    block = parts[1].split("\n\n", 1)[0]
    return without_comments(block)


#: The flag the Mac leg passes so it does not re-render what the shards render.
IGNORE_FLAG = "--pytest-ignore"


def macos_leg_ignores(text: str | None = None) -> list[str]:
    """The `--ignore` arguments the Mac leg passes to pytest (#995).

    One per file the reference-frame matrix already renders, derived from that
    matrix rather than listed beside it. The two jobs ran the same font-gated
    files on the same image: 1,433s of the suite's 2,050s of recorded test time,
    rendered twice, and the Mac leg held a macOS runner for 8.5 minutes on every
    pull request and merge to do it. Under GitHub's five concurrent macOS
    runners that came out of the queue every pull request sits in.

    A second hand-written list here is the whole thing this avoids: a copy that
    drifts is a file rendered twice again, or worse, one rendered nowhere while
    both sides believe the other has it (L41).

    Raises rather than returning an empty list, through `shards()`. An empty
    ignore list is a Mac leg that silently goes back to running everything,
    which reads as a slow job rather than as a broken derivation (L98).
    """
    return [f"--ignore=tests/{name}"
            for name in sorted(reference_frame_files(text))]


def _main() -> int:
    """Print the ignore arguments, one per line, for the workflow to consume.

    A CLI on a test helper because the workflow needs the same answer the guards
    check, and the alternative is the workflow spelling the list itself, which is
    the copy this exists to prevent.
    """
    import sys

    if len(sys.argv) != 2 or sys.argv[1] != IGNORE_FLAG:
        print(f"usage: ci_workflow.py {IGNORE_FLAG}", file=sys.stderr)
        return 2
    for argument in macos_leg_ignores():
        print(argument)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
