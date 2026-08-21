"""#786: recording a deliberate design change, in the right order, in one command.

Changing what a template renders takes several steps and they only work in one
order: bump `MEDIA_DESIGN_VERSIONS`, mirror it into `DesignTokens.swift`,
regenerate `tests/fixtures/design_stamp.json`, re-record the reference frames,
LOOK at them, commit them, and only then record the fingerprints.

Get it wrong and the tools refuse, correctly, but each refusal costs a re-run of
a suite that takes minutes. On 2026-08-20 it was done five times across #753 and
#756 and the order was wrong twice, once recording fingerprints before the
goldens were committed, and once re-recording goldens while the version was still
unbumped.

The refusals are the good part. What was missing is something that does the steps
in the right order in the first place, and refuses BEFORE the expensive render
rather than after it. That is `tools/record_design_change.py`.

Driven here against a throwaway tree and a fake runner, so nothing renders a reel
or touches the real checkout (L2). Every refusal has a test that PRODUCES it
(L151), because a refusal nobody has seen fire is a refusal nobody has tested.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from tools.record_design_change import (
    GOLDEN_DIR,
    Refused,
    prepare,
    unbumped_templates,
)

REPO_ROOT = Path(__file__).resolve().parent.parent


# ── which templates still need their version bumped ───────────────────────────
#
# The check that runs BEFORE anything is rendered, and the one that would have
# saved the second of the two wrong orders.


def test_a_template_whose_fingerprint_moved_without_a_bump_is_named():
    unbumped = unbumped_templates(
        current={"story": "newhash"},
        record={"story": {"fingerprint": "oldhash", "version": 2}},
        versions={"story": 2},
    )

    assert unbumped == ["story"]


def test_a_template_whose_version_moved_with_it_is_not_named():
    unbumped = unbumped_templates(
        current={"story": "newhash"},
        record={"story": {"fingerprint": "oldhash", "version": 2}},
        versions={"story": 3},
    )

    assert unbumped == []


def test_a_template_nothing_moved_in_is_not_named():
    # The ordinary case for every template that is not the one being changed.
    unbumped = unbumped_templates(
        current={"story": "samehash"},
        record={"story": {"fingerprint": "samehash", "version": 2}},
        versions={"story": 2},
    )

    assert unbumped == []


def test_a_template_the_record_has_never_heard_of_counts_as_unbumped():
    # A new template has no recorded version to have been bumped FROM, and
    # treating an absent entry as agreement would let the one case with no
    # history at all through the check that exists to ask about history.
    unbumped = unbumped_templates(
        current={"brand_new": "hash"},
        record={},
        versions={"brand_new": 1},
    )

    assert unbumped == ["brand_new"]


# ── the sequence ──────────────────────────────────────────────────────────────


def _tree(tmp_path: Path) -> Path:
    """A throwaway git repo holding the files the tool reads and writes."""
    repo = tmp_path / "tree"
    (repo / GOLDEN_DIR).mkdir(parents=True)
    (repo / "tests" / "fixtures").mkdir(parents=True, exist_ok=True)
    (repo / GOLDEN_DIR / "story.png").write_bytes(b"before")
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.email=t@example.com",
                    "-c", "user.name=T", "commit", "-q", "-m", "first"], check=True)
    return repo


def _steps_recorder(repo: Path, changes: bytes | None = b"after"):
    """A fake golden run that records that it ran and moves a reference frame."""
    done: list[str] = []

    def stamp(_repo: Path) -> None:
        done.append("stamp")
        (_repo / "tests" / "fixtures" / "design_stamp.json").write_text(
            json.dumps({"templates": {"story": 3}}), encoding="utf-8")

    def runner(_repo: Path, environment: dict[str, str]) -> None:
        done.append("goldens")
        assert environment.get("POSTROLL_UPDATE_GOLDENS") == "1", (
            "the golden run was not asked to re-record, so it checked the "
            "frames against themselves and changed nothing")
        assert "stamp" in done, (
            "the frames were re-recorded before the stamp was regenerated")
        if changes is not None:
            (_repo / GOLDEN_DIR / "story.png").write_bytes(changes)

    return done, stamp, runner


def test_the_steps_run_in_the_one_order_that_works(tmp_path):
    repo = _tree(tmp_path)
    done, stamp, runner = _steps_recorder(repo)

    outcome = prepare(repo, unbumped=[], stamp=stamp, runner=runner)

    assert done == ["stamp", "goldens"]
    assert outcome.changed == ["tests/fixtures/goldens/story.png"]


def test_it_stops_for_a_person_to_look_and_says_what_comes_next(tmp_path):
    """The whole point is that it does NOT go on to record the fingerprints.

    A reference frame is the one artifact a person has to look at, because the
    re-record flag is the single way a broken frame becomes the expectation. So
    this hands back the files to look at and names the next command rather than
    finishing the job for them.
    """
    repo = _tree(tmp_path)
    _, stamp, runner = _steps_recorder(repo)

    outcome = prepare(repo, unbumped=[], stamp=stamp, runner=runner)

    assert "story.png" in outcome.report
    assert "make record-fingerprints" in outcome.report
    assert "look" in outcome.report.lower()
    # Nothing was recorded: the record is the next command's job, after a commit.
    assert not (repo / "tests" / "fixtures" / "media_design_fingerprints.json").exists()


def test_an_unbumped_template_is_refused_before_anything_is_rendered(tmp_path):
    """The second of the two wrong orders, caught at no cost.

    Re-recording the frames first works fine and then the fingerprint tool
    refuses, minutes later, which is the whole complaint in #786. Refusing here
    costs nothing and names both doors.
    """
    repo = _tree(tmp_path)
    done, stamp, runner = _steps_recorder(repo)

    with pytest.raises(Refused) as refusal:
        prepare(repo, unbumped=["story"], stamp=stamp, runner=runner)

    assert done == [], "it rendered before refusing, which is the cost it exists to avoid"
    assert "story" in str(refusal.value)
    assert "record-fingerprints" in str(refusal.value), (
        "the refusal does not name the other door, so somebody whose change "
        "renders identically is told to bump a version they should not bump")


def test_a_run_that_moved_no_frame_at_all_says_so_rather_than_reporting_success(tmp_path):
    """Nothing to look at is not the same as a design change recorded.

    A re-record that rewrote every frame identically means the templates render
    exactly as they did, so this is not a design change and the version bump is
    the wrong door. Reporting it as done would leave somebody looking for frames
    that are not there and reading the silence as approval (L98, L11).
    """
    repo = _tree(tmp_path)
    _, stamp, runner = _steps_recorder(repo, changes=None)

    with pytest.raises(Refused) as refusal:
        prepare(repo, unbumped=[], stamp=stamp, runner=runner)

    assert "no reference frame changed" in str(refusal.value).lower()
    assert "record-fingerprints" in str(refusal.value)


def test_a_tree_with_the_frames_already_uncommitted_is_refused(tmp_path):
    """The frames have to start clean or the report cannot mean anything.

    What it hands back is "these frames changed, look at them". Taken in a tree
    where a frame was already modified, that list is whatever was lying around
    plus whatever this produced, and the two are indistinguishable.
    """
    repo = _tree(tmp_path)
    (repo / GOLDEN_DIR / "story.png").write_bytes(b"left over")
    _, stamp, runner = _steps_recorder(repo)

    with pytest.raises(Refused) as refusal:
        prepare(repo, unbumped=[], stamp=stamp, runner=runner)

    assert "story.png" in str(refusal.value)
    assert "already" in str(refusal.value).lower()


def test_the_make_target_exists_and_points_at_this_tool():
    """Built is not wired (L3). The command #786 asks for is the deliverable."""
    makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")
    recipe = makefile.split("record-design-change:", 1)

    assert len(recipe) == 2, "there is no record-design-change target in the Makefile"
    assert "tools/record_design_change.py" in recipe[1].split("\n\n", 1)[0]
