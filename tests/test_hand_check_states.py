"""The hand check builds the state it names, and never near real data (#866).

Three questions about the app can only be answered by driving it, because
XCUITest cannot read into a PostRoll window (#860). `docs/HAND-CHECK.md` is the
routine that asks them and `PostRollApp/hand-check.sh` is what puts the app into
each state the routine needs.

Several of those states are a deliberately broken events.json. The whole reason
the script exists rather than a paragraph telling somebody to break their own
store is that it points the app at a scratch world through POSTROLL_DATA_DIR,
which `AppPaths.resolveRoot` honours before anything else. These hold it to
that, and to actually producing the state each name promises: a checklist step
whose setup silently did nothing reads as the app behaving correctly, which is
the one verdict it must never be able to give by accident (L98).

Every state here is built with `--no-launch`, so nothing in this file starts an
app, and the scratch world is torn down afterwards.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "PostRollApp" / "hand-check.sh"
WORLD = Path.home() / "Library" / "Caches" / "PostRollHandCheck"
STORE = WORLD / "data" / "events.json"

BROKEN_STORE_STATES = ("corrupt-store", "unreadable-store", "both-broken")
BROKEN_FOLDER_STATES = ("no-code-folder", "both-broken")
EVERY_STATE = ("healthy", "no-code-folder", *BROKEN_STORE_STATES)


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=REPO_ROOT, capture_output=True, text=True, check=False,
    )


@pytest.fixture(autouse=True)
def _clean_world():
    """No state survives into the next test, in either direction.

    An unreadable store is left at mode 000 on purpose, and a folder holding one
    cannot be removed until it is readable again, so the teardown repairs before
    it deletes rather than failing silently and leaving the next test to inherit
    a world nobody chose.
    """
    yield
    if STORE.exists():
        STORE.chmod(0o644)
    subprocess.run(["rm", "-rf", str(WORLD)], check=False)


def test_the_script_is_executable():
    assert SCRIPT.exists(), f"{SCRIPT} is missing, so the checklist has no setup"
    assert os.access(SCRIPT, os.X_OK), "hand-check.sh is not executable"


@pytest.mark.parametrize("state", EVERY_STATE)
def test_every_state_builds_a_world_under_the_scratch_root(state: str):
    """The whole safety claim in one assertion, per state.

    Not "the script mentions POSTROLL_DATA_DIR somewhere", which any comment
    about it would satisfy (L135), but that the store it actually built is
    inside the scratch world and nowhere near the real library.
    """
    result = run(state, "--no-launch")

    assert result.returncode == 0, f"{state} failed: {result.stderr}"
    assert STORE.exists(), f"{state} built no store at {STORE}"
    assert WORLD in STORE.parents
    assert "Documents" not in str(STORE) and "Application Support" not in str(STORE)


def test_a_healthy_state_leaves_a_store_the_app_can_read():
    run("healthy", "--no-launch")

    assert json.loads(STORE.read_text()) == [], "the healthy store is not an empty event list"
    assert os.access(STORE, os.R_OK), "the healthy store is unreadable"


def test_a_corrupt_store_is_present_and_is_not_json():
    """Present and unparseable, which is a different alert from unreadable.

    The app distinguishes them: one says the events could not be READ and offers
    a backup, the other refuses to let Dan past at all. A state that produced
    the wrong one would send the checklist looking for the wrong words.
    """
    run("corrupt-store", "--no-launch")

    assert STORE.exists(), "there is no store at all, which is a third condition again"
    assert os.access(STORE, os.R_OK), "the corrupt store is unreadable, which is the other state"
    with pytest.raises(json.JSONDecodeError):
        json.loads(STORE.read_text())


@pytest.mark.parametrize("state", ("unreadable-store", "both-broken"))
def test_an_unreadable_store_cannot_actually_be_read(state: str):
    """Measured by trying to read it, not by reading its mode off the disk.

    A mode of 000 is what the script sets; whether the file is then genuinely
    unreadable is the thing the checklist depends on, and running as root is one
    way for those two to disagree.
    """
    run(state, "--no-launch")

    with pytest.raises(PermissionError):
        STORE.read_text()


@pytest.mark.parametrize("state", BROKEN_FOLDER_STATES)
def test_a_broken_code_folder_state_leaves_somewhere_that_is_not_a_checkout(state: str):
    run(state, "--no-launch")

    folder = WORLD / "not-a-checkout"
    assert folder.is_dir(), f"{state} built no code folder to point the app at"
    assert not (folder / ".git").exists(), "the folder the app is sent to is a real checkout"
    assert any(folder.iterdir()), (
        "the folder is empty, so the app reports it as missing rather than as "
        "not a checkout, which is a different alert with different words"
    )


# MARK: - The failure paths


def test_an_unknown_command_is_refused_by_name():
    """Named rather than merely refused, because a typo in a checklist step and
    a command that has been removed look identical in a bare usage message."""
    result = run("no-such-state", "--no-launch")

    assert result.returncode != 0, "an unknown command was accepted"
    assert "no-such-state" in result.stderr, (
        f"the refusal does not say what was rejected: {result.stderr}"
    )


def test_repairing_a_world_that_does_not_exist_fails_rather_than_looking_done():
    """Repair is the step that makes Try Again succeed. Reporting success with
    nothing repaired would leave the checklist reading a still broken store as
    the app failing to recover, which is the defect #855 is about."""
    subprocess.run(["rm", "-rf", str(WORLD)], check=False)

    result = run("repair-store")

    assert result.returncode != 0, "repair-store claimed success with no world to repair"
    assert str(WORLD) in result.stderr or "scratch world" in result.stderr


def test_repair_makes_an_unreadable_store_readable_again():
    run("unreadable-store", "--no-launch")

    result = run("repair-store")

    assert result.returncode == 0, result.stderr
    assert json.loads(STORE.read_text()) == [], "the repaired store is not readable"


def test_status_reports_without_building_anything():
    """`status` reads like an inspection, so it must not create a world (L206).

    It is the command somebody runs to find out where they are, which is exactly
    when they have not re-read what it does.
    """
    subprocess.run(["rm", "-rf", str(WORLD)], check=False)

    result = run("status")

    assert result.returncode == 0, result.stderr
    assert not WORLD.exists(), "status built a scratch world just by being asked a question"

# MARK: - It only ever deletes what it made


def test_it_refuses_to_delete_a_directory_it_did_not_create(tmp_path):
    """The script deletes its whole world at the start of every state, and the
    world's location can be overridden. So the delete has to be able to say no.

    Written after a lessons scan pointed at the `rm -rf` and the ordering turned
    out to be genuinely wrong: the delete ran before the check on the path, so
    the check could only ever have confirmed a deletion that had already
    happened (L5).

    A marker file, rather than a rule about what the path looks like. A path
    rule has to be loose enough to allow the override and strict enough to
    refuse a home directory, and there is no such rule; a marker answers the
    question actually being asked, which is whether this script made this
    folder.
    """
    somebody_elses = tmp_path / "not-ours"
    somebody_elses.mkdir()
    (somebody_elses / "a-real-file.txt").write_text("do not delete me")

    env = {**os.environ, "POSTROLL_HAND_CHECK_WORLD": str(somebody_elses)}
    result = subprocess.run(
        ["bash", str(SCRIPT), "healthy", "--no-launch"],
        cwd=REPO_ROOT, capture_output=True, text=True, check=False, env=env,
    )

    assert result.returncode != 0, "the script emptied a folder it had not made"
    assert (somebody_elses / "a-real-file.txt").exists(), "the file was deleted"
    assert str(somebody_elses) in result.stderr, (
        f"the refusal does not name what it refused to delete: {result.stderr}"
    )


def test_it_does_delete_a_world_it_made_itself(tmp_path):
    """The other half, in the same fixture. A refusal that fires on everything
    is not a guard, it is a broken script, and the two look identical from a
    test that only ever checks the refusal (L159)."""
    ours = tmp_path / "ours"
    env = {**os.environ, "POSTROLL_HAND_CHECK_WORLD": str(ours)}

    built = subprocess.run(
        ["bash", str(SCRIPT), "unreadable-store", "--no-launch"],
        cwd=REPO_ROOT, capture_output=True, text=True, check=False, env=env,
    )
    assert built.returncode == 0, built.stderr
    assert (ours / "data" / "events.json").exists()

    ended = subprocess.run(
        ["bash", str(SCRIPT), "end"],
        cwd=REPO_ROOT, capture_output=True, text=True, check=False, env=env,
    )

    assert ended.returncode == 0, ended.stderr
    assert not ours.exists(), (
        "the world it made itself was left behind, including a store at mode "
        "000 that the next run inherits"
    )


def test_ending_a_world_that_was_never_started_is_not_an_error(tmp_path):
    """`end` is the last line of the checklist and gets run whether or not
    anything was started. Failing there would send whoever ran the check looking
    for a problem that is not one."""
    env = {**os.environ, "POSTROLL_HAND_CHECK_WORLD": str(tmp_path / "never-made")}

    result = subprocess.run(
        ["bash", str(SCRIPT), "end"],
        cwd=REPO_ROOT, capture_output=True, text=True, check=False, env=env,
    )

    assert result.returncode == 0, result.stderr

