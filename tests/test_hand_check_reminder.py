"""A merge that touched what only the hand check can see says so (#878).

`docs/HAND-CHECK.md` covers eight questions nothing automated can answer. Until
this existed, nothing anywhere told anybody to run it: the only references were
the README and the script, so a change to the window, the alerts, the quit
confirmation or the Dock landed with no reminder at all. A checklist nobody is
prompted to run is close to no checklist, and this one exists precisely because
those files have no other reviewer (L27).

The mapping from a file to the steps that cover it lives in the checklist
itself, one `Covers:` line per step, rather than in a table beside it. A list
that must mirror another source of truth is derived from it, never maintained
by hand next to it (L41), and here the two would drift in the direction that
matters: a step whose files were never added is a step nothing ever prompts.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pytest
from source_text import without_prose

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL = REPO_ROOT / "tools" / "hand_check_reminder.py"
CHECKLIST = REPO_ROOT / "docs" / "HAND-CHECK.md"

sys.path.insert(0, str(REPO_ROOT / "tools"))


def remind(*changed: str, checklist: Path | None = None) -> subprocess.CompletedProcess[str]:
    arguments = [sys.executable, str(TOOL)]
    if checklist is not None:
        arguments += ["--checklist", str(checklist)]
    return subprocess.run(
        [*arguments, *changed], capture_output=True, text=True, check=False, cwd=REPO_ROOT
    )


# MARK: - The mapping the whole thing rests on


def test_every_step_says_which_files_it_covers():
    """A step with no files is a step no merge can ever prompt, and it looks
    exactly like a step whose files simply were not touched."""
    from hand_check_reminder import read_steps

    steps = read_steps(CHECKLIST)

    assert steps, "no steps were read at all, so every assertion here is about nothing"
    without = [f"{step.number}. {step.title}" for step in steps if not step.covers]
    assert not without, (
        f"these steps name no files, so nothing will ever prompt them: {without}"
    )


def test_every_file_a_step_names_is_really_there():
    """The mapping rots silently otherwise.

    A renamed file leaves a step pointing at nothing, and the reminder then
    stays quiet on exactly the change that should have raised it, while
    reporting itself perfectly healthy (L100).
    """
    from hand_check_reminder import read_steps

    missing = [
        (step.number, path)
        for step in read_steps(CHECKLIST)
        for path in step.covers
        if not (REPO_ROOT / path).exists()
    ]

    assert not missing, (
        f"the checklist names files that are not in the repo: {missing}. A step "
        "pointing at a moved file is silent on the change that should raise it"
    )


def test_the_steps_are_numbered_one_upwards():
    from hand_check_reminder import read_steps

    numbers = [step.number for step in read_steps(CHECKLIST)]

    assert numbers == list(range(1, len(numbers) + 1)), (
        f"the checklist's steps are numbered {numbers}, so a reminder naming a "
        "step number names something the reader cannot find"
    )


# MARK: - What it says about a diff


def test_a_merge_touching_a_covered_file_names_the_step_and_the_file():
    from hand_check_reminder import read_steps

    step = next(s for s in read_steps(CHECKLIST) if s.covers)
    touched = step.covers[0]

    result = remind(touched)

    assert result.returncode == 0, result.stderr
    assert f"Step {step.number}" in result.stdout, (
        f"the reminder does not name the step: {result.stdout}"
    )
    assert step.title in result.stdout, "the reminder does not say what the step asks"
    assert touched in result.stdout, (
        "the reminder does not name the file that raised it, so the reader "
        "cannot tell whether it applies to what they changed"
    )


def test_a_merge_touching_nothing_covered_says_so_rather_than_nothing():
    """Quiet and unread are the same shape in a log.

    A run that printed nothing at all cannot be told from one that failed to
    parse the checklist, and both read as "no hand check needed" (L11).
    """
    result = remind("README.md", "tools/wait_for_checks.py")

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip(), "the reminder said nothing at all"
    assert "no step" in result.stdout.lower() or "nothing" in result.stdout.lower()


def test_a_file_covered_by_two_steps_raises_both():
    """The alerts and their recovery are two steps over one set of files, and
    a reminder naming only the first sends somebody to run half of what the
    change affected."""
    from hand_check_reminder import read_steps

    steps = read_steps(CHECKLIST)
    shared = {
        path: [s.number for s in steps if path in s.covers]
        for step in steps
        for path in step.covers
    }
    covered_twice = {path: numbers for path, numbers in shared.items() if len(numbers) > 1}
    assert covered_twice, (
        "no file is covered by two steps, so this test proves nothing about the "
        "case it was written for (L159)"
    )

    path, numbers = next(iter(covered_twice.items()))
    result = remind(path)

    for number in numbers:
        assert f"Step {number}" in result.stdout, (
            f"{path} is covered by steps {numbers} and the reminder named only "
            f"some of them: {result.stdout}"
        )


# MARK: - The failure paths


def test_being_given_no_files_at_all_is_an_error_not_a_quiet_pass():
    """A merge always changes something, so an empty list means the step that
    computed it failed. Reporting "no hand check needed" there is the reassuring
    answer, and it is the wrong one (L98)."""
    result = remind()

    assert result.returncode != 0, "no changed files was accepted as nothing to do"
    assert "no changed files" in result.stderr.lower(), result.stderr


def test_a_checklist_with_no_mapping_fails_rather_than_reporting_nothing_to_do(tmp_path: Path):
    """The whole tool is one lookup, and an empty lookup answers every question
    with silence. This is the difference between "your change needs no hand
    check" and "the file this reads has stopped saying anything"."""
    hollow = tmp_path / "HAND-CHECK.md"
    hollow.write_text("# The hand check\n\nNo steps here at all.\n")

    result = remind("PostRollApp/Sources/Views/MainWindowView.swift", checklist=hollow)

    assert result.returncode != 0, "a checklist with no steps was read as nothing to run"
    assert "no steps" in result.stderr.lower(), result.stderr


def test_a_missing_checklist_says_which_file_it_could_not_read(tmp_path: Path):
    result = remind("README.md", checklist=tmp_path / "not-here.md")

    assert result.returncode != 0
    assert "not-here.md" in result.stderr


def test_a_step_naming_a_file_that_is_not_there_is_refused_at_run_time(tmp_path: Path):
    """The same drift the suite catches, caught again by the tool itself.

    The suite runs on a pull request and this runs on the merge, and they can
    disagree: a file deleted by one branch while another adds a step naming it
    is green on both and broken on main.
    """
    drifted = tmp_path / "HAND-CHECK.md"
    drifted.write_text(
        "# The hand check\n\n"
        "## 1. A step (#1)\n\n"
        "Covers: `PostRollApp/Sources/Views/MainWindowView.swift`,\n"
        "`PostRollApp/Sources/Views/GoneAway.swift`\n\n"
        "Body.\n"
    )

    result = remind("README.md", checklist=drifted)

    assert result.returncode != 0, "a step naming a file that is gone was used anyway"
    assert "GoneAway.swift" in result.stderr, result.stderr


# MARK: - The merge actually runs it


UI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ui.yml"


def workflow_text() -> str:
    # Read as code, not as prose (#1074): this workflow explains itself
    # in comments that name the very step being checked for.
    text = without_prose(UI_WORKFLOW)
    assert text.strip(), f"{UI_WORKFLOW} is empty, so every assertion below is about nothing"
    return text


def test_the_merge_workflow_runs_the_reminder():
    """A rule that lives only in a document is a hope (L27).

    The whole point of this tool is that nobody has to remember the checklist
    exists, so nothing is settled until something runs it on every merge.
    """
    text = workflow_text()

    assert "tools/hand_check_reminder.py" in text, (
        "no workflow step runs the reminder, so it is a tool nothing invokes and "
        "the checklist is back to being one nobody is prompted to run"
    )


def test_the_reminder_runs_in_a_job_of_its_own():
    """Not a step inside the GUI job.

    Two reasons, either alone enough. A step before the GUI tests that fails
    stops them running, and a step after them never runs when they fail, which
    is exactly the merge somebody most wants the reminder on. A separate job
    also cannot be confused with the GUI result in the checks list.
    """
    text = workflow_text()

    # Only what is under `jobs:`, because a two space key is also how `on:` and
    # `concurrency:` spell their contents, and counting those would let this
    # pass on a workflow declaring one job (L178).
    assert "\njobs:\n" in text, "ui.yml has no jobs block, so this reads nothing"
    body = text.split("\njobs:\n", 1)[1]
    jobs = re.findall(r"^  ([a-z0-9-]+):$", body, re.M)
    assert len(jobs) >= 2, (
        f"ui.yml declares the jobs {jobs}, so the reminder is not one of its own"
    )

    # The reminder's job is whichever block holds the call, and it must not be
    # the one that runs xcodebuild.
    blocks = re.split(r"^  (?=[a-z0-9-]+:$)", body, flags=re.M)
    holding = [block for block in blocks if "tools/hand_check_reminder.py" in block]
    assert len(holding) == 1, (
        f"{len(holding)} job blocks run the reminder, so which one does is undecided"
    )
    assert "xcodebuild" not in holding[0], (
        "the reminder runs inside the GUI test job, where a failure of either "
        "hides the other"
    )


def test_the_reminder_job_reads_the_whole_push_not_just_the_last_commit():
    """A push to main can carry more than one commit.

    Deriving the diff from `HEAD^` reads only the last of them, and the steps
    raised by everything before it are then never named. The compare API is
    given both ends of the push, so the number of commits does not matter, and
    it needs no git history on the runner at all.
    """
    text = workflow_text()

    assert "github.event.before" in text, (
        "the reminder's diff does not come from both ends of the push, so a "
        "push carrying two commits reports on one of them"
    )


def test_the_diff_reaches_the_tool_one_path_per_line():
    """A tracked path with a space in it must not split into two arguments.

    `App Icon/PostRoll App Icon.png` is in this repo today. Word splitting a
    list of filenames means a covered path with a space silently matches no
    step, which is the quiet miss this whole tool exists to prevent: the
    reminder stays green and says nothing needs checking (L98).
    """
    text = workflow_text()

    assert "xargs" in text, (
        "the changed files are passed to the reminder by word splitting, so a "
        "path with a space in it is handed over as two paths and matches nothing"
    )
    assert "hand_check_reminder.py ${changed}" not in text, (
        "the file list is still expanded unquoted into the command line"
    )


def test_a_changed_path_with_a_space_still_raises_its_step(tmp_path: Path):
    """The other half, on the tool itself, so the workflow's shape is not the
    only thing standing between a spaced path and a silent miss (L159)."""
    spaced = tmp_path / "HAND-CHECK.md"
    covered = "PostRollApp/Sources/Views/MainWindowView.swift"
    spaced.write_text(
        f"# The hand check\n\n## 1. A step with a spaced file (#1)\n\n"
        f"Covers: `{covered}`, `App Icon/PostRoll App Icon.png`\n\nBody.\n"
    )

    result = remind("App Icon/PostRoll App Icon.png", checklist=spaced)

    assert result.returncode == 0, result.stderr
    assert "Step 1" in result.stdout, (
        f"a path with a space in it raised nothing: {result.stdout}"
    )
