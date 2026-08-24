"""The hand check builds the state it names, and never near real data (#866).

Eight questions about the app can only be answered by driving it, because
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
app, and each test gets a scratch world of its own.
"""

from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlparse

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "PostRollApp" / "hand-check.sh"

BROKEN_FOLDER_STATES = ("no-code-folder", "both-broken")
EVERY_STATE = ("healthy", "no-code-folder", "corrupt-store", "unreadable-store", "both-broken")


@pytest.fixture
def world(tmp_path: Path):
    """A scratch world of this test's own.

    These used to drive the script's DEFAULT location, which is one fixed path
    under ~/Library/Caches. That passes when the file is run alone and fails
    under `-n auto`: the suite runs in parallel and every test begins by
    deleting and rebuilding that one directory underneath whichever others are
    reading it (L205). Pointing each test at its own directory removes the
    shared thing rather than serialising around it.

    The teardown repairs before it deletes. An unreadable store is left at mode
    000 on purpose, and a folder holding one cannot be removed until it is
    readable again.
    """
    place = tmp_path / "world"
    yield place
    store = place / "data" / "events.json"
    if store.exists():
        store.chmod(0o644)
    subprocess.run(["rm", "-rf", str(place)], check=False)


def run(world: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=REPO_ROOT, capture_output=True, text=True, check=False,
        env={**os.environ, "POSTROLL_HAND_CHECK_WORLD": str(world)},
    )


def store_in(world: Path) -> Path:
    return world / "data" / "events.json"


def test_the_script_is_executable():
    assert SCRIPT.exists(), f"{SCRIPT} is missing, so the checklist has no setup"
    assert os.access(SCRIPT, os.X_OK), "hand-check.sh is not executable"


@pytest.mark.parametrize("state", EVERY_STATE)
def test_every_state_builds_a_world_where_it_was_told_to(state: str, world: Path):
    """The whole safety claim in one assertion, per state.

    Not "the script mentions POSTROLL_DATA_DIR somewhere", which any comment
    about it would satisfy (L135), but that the store it actually built is
    inside the world it was pointed at and nowhere near the real library.
    """
    result = run(world, state, "--no-launch")

    assert result.returncode == 0, f"{state} failed: {result.stderr}"
    store = store_in(world)
    assert store.exists(), f"{state} built no store at {store}"
    assert world in store.parents
    assert "Documents" not in str(store) and "Application Support" not in str(store)


def test_a_healthy_state_leaves_a_store_the_app_can_read(world: Path):
    run(world, "healthy", "--no-launch")

    store = store_in(world)
    assert json.loads(store.read_text()) == [], "the healthy store is not an empty event list"
    assert os.access(store, os.R_OK), "the healthy store is unreadable"


def test_a_corrupt_store_is_present_and_is_not_json(world: Path):
    """Present and unparseable, which is a different alert from unreadable.

    The app distinguishes them: one says the events could not be READ and offers
    a backup, the other refuses to let Dan past at all. A state that produced
    the wrong one would send the checklist looking for the wrong words.
    """
    run(world, "corrupt-store", "--no-launch")

    store = store_in(world)
    assert store.exists(), "there is no store at all, which is a third condition again"
    assert os.access(store, os.R_OK), "the corrupt store is unreadable, which is the other state"
    with pytest.raises(json.JSONDecodeError):
        json.loads(store.read_text())


@pytest.mark.parametrize("state", ("unreadable-store", "both-broken"))
def test_an_unreadable_store_cannot_actually_be_read(state: str, world: Path):
    """Measured by trying to read it, not by reading its mode off the disk.

    A mode of 000 is what the script sets; whether the file is then genuinely
    unreadable is the thing the checklist depends on, and running as root is one
    way for those two to disagree.
    """
    run(world, state, "--no-launch")

    with pytest.raises(PermissionError):
        store_in(world).read_text()


@pytest.mark.parametrize("state", BROKEN_FOLDER_STATES)
def test_a_broken_code_folder_state_is_not_a_checkout(state: str, world: Path):
    run(world, state, "--no-launch")

    folder = world / "not-a-checkout"
    assert folder.is_dir(), f"{state} built no code folder to point the app at"
    assert not (folder / ".git").exists(), "the folder the app is sent to is a real checkout"
    assert any(folder.iterdir()), (
        "the folder is empty, so the app reports it as missing rather than as "
        "not a checkout, which is a different alert with different words"
    )


# MARK: - The failure paths


def test_an_unknown_command_is_refused_by_name(world: Path):
    """Named rather than merely refused, because a typo in a checklist step and
    a command that has been removed look identical in a bare usage message."""
    result = run(world, "no-such-state", "--no-launch")

    assert result.returncode != 0, "an unknown command was accepted"
    assert "no-such-state" in result.stderr, (
        f"the refusal does not say what was rejected: {result.stderr}"
    )


def test_repairing_a_world_that_does_not_exist_fails_rather_than_looking_done(world: Path):
    """Repair is the step that makes Try Again succeed. Reporting success with
    nothing repaired would leave the checklist reading a still broken store as
    the app failing to recover, which is the defect #855 is about."""
    result = run(world, "repair-store")

    assert result.returncode != 0, "repair-store claimed success with no world to repair"
    assert str(world) in result.stderr or "scratch world" in result.stderr


def test_repair_makes_an_unreadable_store_readable_again(world: Path):
    run(world, "unreadable-store", "--no-launch")

    result = run(world, "repair-store")

    assert result.returncode == 0, result.stderr
    assert json.loads(store_in(world).read_text()) == [], "the repaired store is not readable"


def test_status_reports_without_building_anything(world: Path):
    """`status` reads like an inspection, so it must not create a world (L206).

    It is the command somebody runs to find out where they are, which is exactly
    when they have not re-read what it does.
    """
    result = run(world, "status")

    assert result.returncode == 0, result.stderr
    assert not world.exists(), "status built a scratch world just by being asked a question"


# MARK: - It only ever deletes what it made


def test_it_refuses_to_delete_a_directory_it_did_not_create(world: Path):
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
    world.mkdir(parents=True)
    (world / "a-real-file.txt").write_text("do not delete me")

    result = run(world, "healthy", "--no-launch")

    assert result.returncode != 0, "the script emptied a folder it had not made"
    assert (world / "a-real-file.txt").exists(), "the file was deleted"
    assert str(world) in result.stderr, (
        f"the refusal does not name what it refused to delete: {result.stderr}"
    )


def test_it_does_delete_a_world_it_made_itself(world: Path):
    """The other half, in the same fixture. A refusal that fires on everything
    is not a guard, it is a broken script, and the two look identical from a
    test that only ever checks the refusal (L159)."""
    built = run(world, "unreadable-store", "--no-launch")
    assert built.returncode == 0, built.stderr
    assert store_in(world).exists()

    ended = run(world, "end")

    assert ended.returncode == 0, ended.stderr
    assert not world.exists(), (
        "the world it made itself was left behind, including a store at mode "
        "000 that the next run inherits"
    )


def test_ending_a_world_that_was_never_started_is_not_an_error(world: Path):
    """`end` is the last line of the checklist and gets run whether or not
    anything was started. Failing there would send whoever ran the check looking
    for a problem that is not one."""
    result = run(world, "end")

    assert result.returncode == 0, result.stderr


# MARK: - The state a generation can actually be started from (#879)
#
# Step 8 of the checklist watches what the Dock and Notification Center say
# while work runs, and both halves of it begin by starting a generation. Every
# state above builds an EMPTY store, and `Generate All` is disabled until an
# event has at least one photo, so the step was not runnable as written: the
# button it tells you to press is grey, on a screen you cannot reach.

# What the script copies at most, so a folder holding a whole shoot does not
# turn a hand check into a full week's API spend. Stated here as well as in the
# script because the point of the cap is that whoever runs the check is TOLD
# when it fired.
SEED_PHOTO_CAP = 8

# The seeded event's date, as the app reads it. `EventStore` decodes with a
# plain JSONDecoder, whose default strategy for a Date is seconds since the 2001
# reference date. Derived here from the date itself rather than copied from the
# script, so the two sides of the check do not come from one lookup (L70).
SEED_DATE = datetime(2026, 9, 1, tzinfo=timezone.utc)
APPLE_REFERENCE_DATE = datetime(2001, 1, 1, tzinfo=timezone.utc)


@pytest.fixture
def shoot(tmp_path: Path) -> Path:
    """A folder of images standing in for one of Dan's shoot folders."""
    folder = tmp_path / "shoot"
    folder.mkdir()
    for index in range(3):
        (folder / f"DSC0{index}.JPG").write_bytes(b"stand-in for a photograph")
    return folder


def seeded_event(world: Path) -> dict:
    events = json.loads(store_in(world).read_text())
    assert len(events) == 1, f"the seeded store holds {len(events)} events rather than one"
    return events[0]


#: The days the seeding deals photographs onto. Friday cannot be generated and
#: Tuesday carries reel slots this fixture has nothing to fill, so those two are
#: deliberately not used.
SEEDED_DAYS = ("monday", "wednesday")


def photo_files(event: dict) -> list[Path]:
    """The files the seeded event's photo paths actually name, across every day.

    Through the URL, because that is what the app does with them. A path that
    survives as a string and does not survive being turned back into a file is
    a day with no photos, which is the state this whole command exists to avoid.
    """
    files = []
    for day in SEEDED_DAYS:
        for url in event["days"][day]["photoPaths"]:
            assert url.startswith("file://"), (
                f"{url} is not a file URL, so the app cannot open it"
            )
            files.append(Path(unquote(urlparse(url).path)))
    return files


def test_seeding_with_no_folder_refuses_before_it_deletes_anything(world: Path):
    """A refusal has to come before the world is rebuilt, not after.

    Every state starts by deleting the world, so an argument checked afterwards
    can only confirm a deletion that has already happened (L5). Here that would
    take away the state whoever ran the previous step is standing in.
    """
    world.mkdir(parents=True)
    (world / ".postroll-hand-check").write_text("made by an earlier step")
    (world / "data").mkdir()
    (world / "data" / "events.json").write_text("[]")

    result = run(world, "seeded", "--no-launch")

    assert result.returncode != 0, "seeded accepted no photo folder at all"
    # The words, not merely a non-zero exit. Every unknown command already
    # fails and prints a usage message mentioning the code folder, so a check
    # for a refusal, or for the word folder, is answered by the command not
    # existing at all (L140).
    assert "photo folder" in result.stderr.lower(), (
        f"the refusal does not say a photo folder is what is missing: {result.stderr}"
    )
    assert (world / "data" / "events.json").exists(), (
        "the world was torn down by a command that then refused to build one"
    )


def test_seeding_from_a_folder_with_no_images_refuses_and_names_it(world: Path, tmp_path: Path):
    """The setup that silently does nothing is the one to be afraid of.

    A seeded event with no photos leaves `Generate All` disabled, which looks
    exactly like the app being broken to somebody following the checklist, and
    reads as a passed step to somebody skimming it (L98).
    """
    empty = tmp_path / "not-a-shoot"
    empty.mkdir()
    (empty / "notes.txt").write_text("no photographs in here")

    result = run(world, "seeded", str(empty), "--no-launch")

    assert result.returncode != 0, "seeded built an event out of a folder with no photos"
    assert str(empty) in result.stderr, (
        f"the refusal does not name the folder it was pointed at: {result.stderr}"
    )


def test_a_seeded_event_is_one_a_generation_can_be_started_from(world: Path, shoot: Path):
    """The three things that decide whether the button is even reachable.

    The stage, because `EventDetailView` shows the generation screen for
    `.photosAssigned` and something else for every other stage. The photos,
    because `canGenerate` is `totalPhotos > 0`. And the OCR result, because
    `PythonBridge.buildManifest` throws "No OCR result" before the pipeline is
    started at all, so an event without one can only ever produce a failure.
    """
    result = run(world, "seeded", str(shoot), "--no-launch")
    assert result.returncode == 0, result.stderr

    event = seeded_event(world)
    assert event["stage"] == "Photos Assigned", (
        f"the seeded event is at stage {event['stage']!r}, so the generation "
        "screen is not the one the app shows for it"
    )
    assert "ocrResult" in event, (
        "the seeded event has no OCR result, so buildManifest refuses the run "
        "before the pipeline starts and only the failure half of step 8 is reachable"
    )
    for day in SEEDED_DAYS:
        assert event["days"][day]["day"] == day
    assert len(photo_files(event)) == 3, "the seeded days do not carry the photos they were given"

    # Spread, not piled onto one day. A single day's run can be over before
    # anybody has watched the Dock clock long enough to tell a moving number
    # from a frozen one, which is the question the step exists to ask.
    counts = [len(event["days"][day]["photoPaths"]) for day in SEEDED_DAYS]
    assert all(count > 0 for count in counts), (
        f"the photographs landed on one day only: {counts}"
    )


def test_the_seeded_photos_are_real_files_inside_the_scratch_world(world: Path, shoot: Path):
    """Copied in, not pointed at where they came from.

    The run writes its output beside the data root, and the checklist deletes
    the whole world when it is finished. A world holding paths into a real shoot
    folder would make `end` a command whose blast radius depends on what it was
    seeded from.
    """
    run(world, "seeded", str(shoot), "--no-launch")

    for photo in photo_files(seeded_event(world)):
        assert photo.exists(), f"{photo} is named by the event and is not there"
        assert world in photo.parents, f"{photo} is outside the scratch world"


def test_seeding_leaves_the_folder_it_was_pointed_at_alone(world: Path, shoot: Path):
    """It is given a real shoot folder, so it must only ever read from it."""
    before = sorted(path.name for path in shoot.iterdir())

    result = run(world, "seeded", str(shoot), "--no-launch")

    assert result.returncode == 0, result.stderr
    assert sorted(path.name for path in shoot.iterdir()) == before
    assert photo_files(seeded_event(world)), (
        "nothing was seeded, so leaving the source alone proves nothing (L159)"
    )


def test_seeding_says_so_when_it_takes_fewer_photos_than_it_found(world: Path, tmp_path: Path):
    """A cap that is not reported reads as "it took everything" (L107 territory).

    Somebody who pointed this at a 600 photo shoot and was told nothing would
    reasonably read the captions afterwards as the pipeline's opinion of the
    whole shoot.
    """
    folder = tmp_path / "whole-shoot"
    folder.mkdir()
    found = SEED_PHOTO_CAP + 3
    for index in range(found):
        (folder / f"DSC{index:04d}.jpg").write_bytes(b"stand-in for a photograph")

    result = run(world, "seeded", str(folder), "--no-launch")

    assert result.returncode == 0, result.stderr
    assert len(photo_files(seeded_event(world))) == SEED_PHOTO_CAP
    assert str(SEED_PHOTO_CAP) in result.stdout and str(found) in result.stdout, (
        f"the cap fired and the output does not say how many were left: {result.stdout}"
    )


def test_the_seeded_date_is_written_the_way_the_app_reads_it(world: Path, shoot: Path):
    """A date in the wrong encoding is not a wrong date, it is an unreadable store.

    `EventStore` uses a plain JSONDecoder, so a Date is a number of seconds
    since 2001 and an ISO string fails to decode. The whole store then fails
    with it, and the state built to be healthy raises the corrupt store alert
    instead, which is a different step of this same checklist.
    """
    run(world, "seeded", str(shoot), "--no-launch")

    date = seeded_event(world)["date"]
    assert isinstance(date, (int, float)) and not isinstance(date, bool), (
        f"the seeded date is {date!r}, which JSONDecoder cannot read as a Date"
    )
    assert date == (SEED_DATE - APPLE_REFERENCE_DATE).total_seconds()


def test_a_seeded_world_is_still_a_scratch_world(world: Path, shoot: Path):
    """The safety claim every other state is held to, on this one too."""
    result = run(world, "seeded", str(shoot), "--no-launch")

    assert result.returncode == 0, result.stderr
    store = store_in(world)
    assert store.exists(), "there is no store, so where it is not is not a measurement"
    assert world in store.parents
    assert "Documents" not in str(store) and "Application Support" not in str(store)


def test_a_seeded_world_can_also_have_the_broken_code_folder(world: Path, shoot: Path):
    """The failure half of step 8 needs both at once, in one world.

    A run fails there because the pipeline is not where the app was told it is,
    and it has to be a run that could otherwise have started: an event with no
    photos never reaches the bridge, so it produces no failure to be told about
    either. Before this the two states were separate commands, each of which
    began by deleting what the other had built.
    """
    result = run(world, "seeded", str(shoot), "--no-code-folder", "--no-launch")

    assert result.returncode == 0, result.stderr
    assert len(photo_files(seeded_event(world))) == 3, (
        "the broken code folder cost the world its seeded event"
    )
    folder = world / "not-a-checkout"
    assert folder.is_dir() and not (folder / ".git").exists()
    assert any(folder.iterdir()), (
        "the folder is empty, so the app reports it as missing rather than as "
        "not a checkout, which is a different alert with different words"
    )
    assert "not-a-checkout" in result.stdout, (
        f"nothing says the app is being pointed away from the checkout: {result.stdout}"
    )
