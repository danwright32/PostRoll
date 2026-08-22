"""#286: every cached template says which design made it, not just the collage.

#160 gave the collage a design version, so a collage rendered before the
gallery redesign is badged on the review screen instead of quietly rendering
the old look forever. The other templates went through the same redesign
(c65a0d6) and got no stamp, so a cached Thursday scroll reel, Tuesday reel,
before/after or story from before it keeps rendering the old design with
nothing saying so. The reels are the worst case: re-rendering one is expensive
enough that nobody does it speculatively, so a stale one survives longest.

The stamp is one record per day folder rather than one file per asset, because
"is this day's output current" is then one read rather than one per asset, and
regenerating a day rewrites all of it at once anyway.

`PostRollApp/Sources/Services/DesignStamp.swift` is the reading half.
"""

from __future__ import annotations

import json
import os
import re
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest

from postroll.media import design_stamp
from postroll.media import design_tokens as tokens
from tests.source_text import swift_without_comments


REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATE_MEDIA = REPO_ROOT / "postroll" / "ai" / "generate_media.py"
SWIFT_TOKENS = REPO_ROOT / "PostRollApp" / "Sources" / "DesignTokens.swift"
SWIFT_STAMP = REPO_ROOT / "PostRollApp" / "Sources" / "Services" / "DesignStamp.swift"


def _asset_stems_written_into_a_day_folder() -> set[str]:
    """Every `day_dir / "name.ext"` literal in generate_media.py, by stem.

    Read out of the code rather than listed in this file. A registry that holds
    only what somebody remembered to add exempts the newest template from the
    very check meant to catch it, and reports green while blind (L96). Deriving
    it means adding a template to generate_media.py fails this suite until its
    design version is declared, or it is declared as carrying no design.
    """
    text = GENERATE_MEDIA.read_text(encoding="utf-8")
    stems = set()
    for name in re.findall(r'day_dir / "([^"]+)"', text):
        if name.endswith(".tmp"):
            # An intermediate that is renamed over the real output, so it never
            # survives the run and cannot be a cached asset.
            continue
        stems.add(Path(name).stem)
    return stems


# ── the table covers what the code actually renders ───────────────────────────

def test_the_code_writes_at_least_the_templates_we_think_it_does():
    # Guards the derivation above: if the `day_dir / "..."` shape ever changes,
    # the scan would silently return nothing and every check below would pass
    # by finding no work to do.
    stems = _asset_stems_written_into_a_day_folder()
    assert {"collage", "story", "before_after", "reel_scroll"} <= stems


def test_every_asset_a_day_can_cache_is_declared_one_way_or_the_other():
    versioned = set(tokens.MEDIA_DESIGN_VERSIONS)
    exempt = set(tokens.UNVERSIONED_DAY_FILES)
    undeclared = _asset_stems_written_into_a_day_folder() - versioned - exempt
    assert not undeclared, (
        f"generate_media.py caches {sorted(undeclared)} in a day folder with no "
        "declared design version, so a copy rendered by an older design would "
        "never be badged. Add it to MEDIA_DESIGN_VERSIONS, or to "
        "UNVERSIONED_DAY_FILES if it carries no design.")


def test_nothing_is_declared_both_versioned_and_exempt():
    overlap = set(tokens.MEDIA_DESIGN_VERSIONS) & set(tokens.UNVERSIONED_DAY_FILES)
    assert not overlap, f"{sorted(overlap)} is declared as both"


def test_the_collage_version_has_one_home():
    # The collage's number is still COLLAGE_DESIGN_VERSION, because the layout
    # sidecar #160 shipped reads it. Two numbers meant to agree, maintained by
    # hand beside each other, drift the moment one is bumped (L41).
    assert tokens.MEDIA_DESIGN_VERSIONS["collage"] == tokens.COLLAGE_DESIGN_VERSION


def test_every_bumped_template_records_when_it_changed():
    """The pair, in both directions (#804).

    A bumped template with no date is not badged on any unstamped asset, so the
    whole library stays uncovered for exactly the change that needed covering,
    silently. A date on a template that was never bumped claims a design change
    that did not happen, and would badge every asset older than the day
    somebody first wrote a number down.
    """
    missing = sorted(name for name, version in tokens.MEDIA_DESIGN_VERSIONS.items()
                     if version > 1 and name not in tokens.MEDIA_DESIGN_CHANGED)
    assert not missing, (
        f"these templates have been bumped past their first version and record "
        f"no date it happened: {missing}. Unstamped assets of theirs are badged "
        "by nothing, which is the state #804 was filed about. Add the date the "
        "bump landed to MEDIA_DESIGN_CHANGED.")

    invented = sorted(name for name in tokens.MEDIA_DESIGN_CHANGED
                      if tokens.MEDIA_DESIGN_VERSIONS.get(name) == 1)
    assert not invented, (
        f"these templates are still at their first version and record a design "
        f"change anyway: {invented}. There was no change; the date only says "
        "when a number was first written down, and every asset older than it "
        "would be badged for nothing.")

    unknown = sorted(set(tokens.MEDIA_DESIGN_CHANGED) - set(tokens.MEDIA_DESIGN_VERSIONS))
    assert not unknown, (
        f"MEDIA_DESIGN_CHANGED names templates with no declared version: "
        f"{unknown}. Nothing reads them, so the date is decorative.")


def test_every_recorded_change_names_the_version_it_belongs_to():
    """The half `test_every_bumped_template_records_when_it_changed` cannot see (#808).

    That one asks only that a date EXISTS for a template past its first
    version, so a version edited straight into the table, which is how several
    past bumps happened rather than through `make record-design-change`, passes
    with the date of the PREVIOUS bump. Every asset made between that date and
    this one then reads as current, which is the silence #804 was filed about,
    now with a guard in place that reads as protection.

    Naming the version the date belongs to is what makes the drift visible in
    the file itself: the two facts sit on one line, and moving one without the
    other fails here rather than passing quietly.
    """
    stale = tokens.changes_recorded_for_another_version(
        tokens.MEDIA_DESIGN_VERSIONS, tokens.MEDIA_DESIGN_CHANGED)
    assert not stale, (
        f"these templates record a design change for a version they are no "
        f"longer at: {stale}. The date beside it is the day the OLD version "
        "landed, so every unstamped asset made since then reads as current. "
        "Set both halves of the entry in MEDIA_DESIGN_CHANGED to the version "
        "being shipped and the day it shipped, and mirror the day in "
        "PostRollApp/Sources/DesignTokens.swift.")


def test_a_change_left_behind_by_a_bump_is_named():
    """The guard, seen to fail (L1).

    Driven against a made-up pair rather than the real table, which is expected
    to be clean: a check that only ever runs on correct data has never been
    shown to notice incorrect data.
    """
    stale = tokens.changes_recorded_for_another_version(
        versions={"story": 3, "cover": 2},
        changed={"story": tokens.DesignChange(version=2, day="2026-08-21"),
                 "cover": tokens.DesignChange(version=2, day="2026-08-21")})

    assert stale == ["story"]


def test_a_change_recording_the_current_version_is_not_named():
    stale = tokens.changes_recorded_for_another_version(
        versions={"story": 3},
        changed={"story": tokens.DesignChange(version=3, day="2026-08-22")})

    assert stale == []


def test_a_change_recorded_for_a_version_ahead_of_the_table_is_named():
    """A rollback is the same drift in the other direction.

    Putting a version back without putting its date back leaves the entry
    describing a design that is no longer rendered, and the date it carries is
    then for assets nobody can produce.
    """
    stale = tokens.changes_recorded_for_another_version(
        versions={"story": 2},
        changed={"story": tokens.DesignChange(version=3, day="2026-08-22")})

    assert stale == ["story"]


def test_every_recorded_change_is_a_date_that_has_happened():
    """A date is compared against a file's own; a bad one decides silently.

    An unparseable date raises here rather than at the moment somebody opens a
    day folder, and a date in the FUTURE would badge every asset there is,
    including ones rendered by the current design, which is the alarm nobody
    reads (L36).
    """
    from datetime import date as _date

    for name, entry in sorted(tokens.MEDIA_DESIGN_CHANGED.items()):
        when = entry.day
        parsed = _date.fromisoformat(when)
        assert parsed <= _date.today(), (
            f"{name} records a design change on {when}, which has not happened "
            "yet, so every cached asset is older than it and would be badged")


def test_every_declared_version_is_a_real_version():
    for name, version in tokens.MEDIA_DESIGN_VERSIONS.items():
        assert isinstance(version, int), name
        assert version >= 1, name


# ── the stamp records what the day rendered ───────────────────────────────────

def test_the_stamp_records_the_version_of_each_template_the_day_rendered(tmp_path):
    design_stamp.write_design_stamp(tmp_path, ["reel_scroll", "story"])

    doc = json.loads(design_stamp.design_stamp_path(tmp_path).read_text(encoding="utf-8"))
    assert doc["templates"] == {
        "reel_scroll": tokens.MEDIA_DESIGN_VERSIONS["reel_scroll"],
        "story": tokens.MEDIA_DESIGN_VERSIONS["story"],
    }


def test_a_stamp_that_does_not_read_back_raises(tmp_path):
    # The reader treats unreadable and absent as the same answer (no evidence),
    # which is right for the badge but means a write that silently failed would
    # disable the guard with nothing saying so, forever. This repo has been
    # bitten by a read that lied about a file under macOS's protections before,
    # so the write proves itself rather than assuming it landed.
    import postroll.media.design_stamp as mod

    original = mod.read_design_stamp
    try:
        mod.read_design_stamp = lambda _: {}
        with pytest.raises(OSError, match="did not read back"):
            design_stamp.write_design_stamp(tmp_path, ["story"])
    finally:
        mod.read_design_stamp = original


def test_writing_an_undeclared_template_raises(tmp_path):
    # Fail loud. A stamp that silently skipped what it did not recognise would
    # leave that template permanently exempt from the staleness check while the
    # file still reads as if it covered the whole day.
    with pytest.raises(KeyError):
        design_stamp.write_design_stamp(tmp_path, ["reel_teleport"])


def test_the_stamp_reads_back(tmp_path):
    design_stamp.write_design_stamp(tmp_path, ["collage"])
    assert design_stamp.read_design_stamp(tmp_path) == {
        "collage": tokens.MEDIA_DESIGN_VERSIONS["collage"]
    }


def test_a_day_rendered_before_the_stamp_existed_reads_as_no_record(tmp_path):
    # Every day folder on disk today is in this state, and there is no way to
    # tell which design made them, so they read as unstamped rather than
    # current.
    assert design_stamp.read_design_stamp(tmp_path) == {}


def test_a_corrupt_stamp_reads_as_no_record_rather_than_raising(tmp_path):
    design_stamp.design_stamp_path(tmp_path).write_text("{not json", encoding="utf-8")
    assert design_stamp.read_design_stamp(tmp_path) == {}


def test_a_stamp_of_the_wrong_shape_reads_as_no_record(tmp_path):
    design_stamp.design_stamp_path(tmp_path).write_text(
        json.dumps({"templates": "reel_scroll"}), encoding="utf-8")
    assert design_stamp.read_design_stamp(tmp_path) == {}


@pytest.mark.parametrize("bad", ["1", True, 1.5, None, [1], {"v": 1}])
def test_a_version_that_is_not_a_whole_number_is_dropped(tmp_path, bad):
    # Dropped per entry, not all-or-nothing: the good neighbour survives, which
    # is what the Swift reader also has to do or the two disagree about the same
    # file (L26). `True` is here because it answers to an integer in both
    # languages, and 1 is a plausible-looking version.
    design_stamp.design_stamp_path(tmp_path).write_text(
        json.dumps({"templates": {"story": bad, "collage": 1}}), encoding="utf-8")
    assert design_stamp.read_design_stamp(tmp_path) == {"collage": 1}


# ── which templates are out of date ───────────────────────────────────────────

def _cache(day_dir: Path, *names: str) -> None:
    """Put an asset on disk for each named template, as a render would."""
    suffix = {"reel_scroll": ".mp4", "reel_morph": ".mp4", "reel_slider": ".mp4",
              "reel_screen": ".mp4", "reel_clip": ".mp4"}
    for name in names:
        (day_dir / f"{name}{suffix.get(name, '.png')}").write_bytes(b"x")


def test_a_day_stamped_with_the_current_design_is_not_stale(tmp_path):
    _cache(tmp_path, "reel_scroll", "story")
    design_stamp.write_design_stamp(tmp_path, ["reel_scroll", "story"])
    assert design_stamp.stale_templates(tmp_path) == []


def test_a_template_stamped_older_than_the_current_design_is_stale(tmp_path):
    _cache(tmp_path, "reel_scroll", "story")
    design_stamp.design_stamp_path(tmp_path).write_text(
        json.dumps({"templates": {
            "reel_scroll": 0,
            "story": tokens.MEDIA_DESIGN_VERSIONS["story"],
        }}), encoding="utf-8")
    assert design_stamp.stale_templates(tmp_path) == ["reel_scroll"]


def _aged(day_dir: Path, name: str, when: str) -> None:
    """Set a cached asset's modification date, as an old render would have it."""
    stamp = datetime.fromisoformat(f"{when}T12:00:00").timestamp()
    for path in day_dir.iterdir():
        if path.stem == name:
            os.utime(path, (stamp, stamp))
            return
    raise AssertionError(f"no cached asset for {name} in {day_dir}")


def _before(name: str) -> str:
    """The day before `name`'s design last changed."""
    return (date.fromisoformat(tokens.MEDIA_DESIGN_CHANGED[name].day)
            - timedelta(days=1)).isoformat()


def _bumped() -> str:
    """A template whose design has actually changed, taken from the record.

    Named from the table rather than typed here, so these tests follow the
    versions rather than pinning one template that may go back to being the
    only one at its first version (L41).
    """
    return sorted(tokens.MEDIA_DESIGN_CHANGED)[0]


def test_an_unstamped_asset_older_than_its_design_change_is_stale(tmp_path):
    """The whole of #804.

    The colophon lift bumped `before_after` to 2 and nothing on disk could
    notice: the badge only fired on a recorded version, and measured that day
    there were ZERO stamps under the preview library, so the check covered no
    asset that existed. Dan published the 7 August render of
    `6. Friday/before_after.png`, with the wordmark clipped against the bottom
    edge, and the app had no way to say so.

    The file's own modification date is evidence nobody has to invent.
    """
    name = _bumped()
    _cache(tmp_path, name)
    _aged(tmp_path, name, _before(name))

    assert design_stamp.stale_templates(tmp_path) == [name]


def test_an_unstamped_asset_newer_than_its_design_change_is_not_stale(tmp_path):
    """The other direction, and it is what keeps this off the whole library.

    An asset rendered after the change was rendered by the current design, and
    badging it would send somebody to rebuild something that is not out of date.
    """
    name = _bumped()
    _cache(tmp_path, name)
    _aged(tmp_path, name, date.today().isoformat())

    assert design_stamp.stale_templates(tmp_path) == []


def test_an_unstamped_template_whose_design_never_changed_is_not_reported(tmp_path):
    """No bump, no claim.

    A template still at its first version has no recorded design CHANGE, only a
    date on which somebody first wrote a number down, and an asset older than
    that was made by the same design. Badging it would be an accusation from the
    absence of evidence, which is the thing the version rule exists not to do
    (L98, and the 66 folders badged at once on 2026-08-10).
    """
    unbumped = sorted(set(tokens.MEDIA_DESIGN_VERSIONS) - set(tokens.MEDIA_DESIGN_CHANGED))
    assert unbumped, (
        "every template has a recorded design change, so this case cannot be "
        "reached and the rule it covers is untested rather than unnecessary")

    for name in unbumped:
        _cache(tmp_path, name)
        _aged(tmp_path, name, "2020-01-01")
    assert design_stamp.stale_templates(tmp_path) == []


def test_a_stamp_still_decides_over_the_file_date(tmp_path):
    """A record beats an inference, in both directions.

    The stamp is a measurement of what rendered the day; the file date is
    evidence about when. Where there is a record, it answers, so an asset
    stamped CURRENT is not badged for being old and one stamped BEHIND is
    badged however new the file is.
    """
    name = _bumped()
    _cache(tmp_path, name)
    _aged(tmp_path, name, _before(name))
    design_stamp.write_design_stamp(tmp_path, [name])

    assert design_stamp.stale_templates(tmp_path) == []


def test_an_asset_whose_date_cannot_be_read_is_not_reported(tmp_path):
    """Unreadable is not old.

    `stat` failing says nothing about when the file was made, and reporting on
    it would be a claim the check never measured (L11).

    Driven at the predicate with a path that is not there, rather than by
    replacing `Path.stat` for the whole scan: that also breaks the `iterdir`
    and `is_file` the scan runs first, so the test would pass on a folder it
    could not read at all rather than on the case it names (L140).
    """
    name = _bumped()

    assert design_stamp.predates_its_design_change(name, tmp_path / "not-here.png") is False
    # And the positive case in the same fixture, so the False above is the
    # unreadable date rather than a predicate that answers False for everything
    # (L159).
    _cache(tmp_path, name)
    _aged(tmp_path, name, _before(name))
    real = design_stamp.cached_assets(tmp_path)[name]
    assert design_stamp.predates_its_design_change(name, real) is True


def test_an_asset_with_no_record_and_no_change_to_be_older_than_is_not_reported(tmp_path):
    # The badge fires on evidence, never on the absence of it. Measured on real
    # data (2026-08-10): every one of the 66 day folders on Dan's machine holds
    # assets and no stamp, so treating "no record" as stale badged all 66 at
    # once, and a badge on every day is one nobody reads (L36).
    #
    # #804 narrowed that rather than reversed it. An unstamped asset is still
    # not reported for being unstamped; it is reported when its own file date
    # puts it before the day that template's design changed, which is evidence
    # rather than absence. A template with no recorded change still says
    # nothing, whatever the file date.
    _cache(tmp_path, "collage", "reel_clip")
    _aged(tmp_path, "collage", "2020-01-01")
    _aged(tmp_path, "reel_clip", "2020-01-01")
    assert design_stamp.stale_templates(tmp_path) == []


def test_an_asset_the_stamp_does_not_mention_is_not_reported(tmp_path):
    # Same rule inside a stamped day: nothing recorded, nothing claimed.
    _cache(tmp_path, "reel_scroll", "story")
    design_stamp.write_design_stamp(tmp_path, ["story"])
    assert design_stamp.stale_templates(tmp_path) == []


def test_a_recorded_asset_beside_an_unrecorded_one_is_still_caught(tmp_path):
    # The silence must not spread: an asset the stamp DOES vouch for, at an old
    # version, is still evidence, whatever its neighbours are missing.
    _cache(tmp_path, "reel_scroll", "story")
    design_stamp.design_stamp_path(tmp_path).write_text(
        json.dumps({"templates": {"story": 0}}), encoding="utf-8")
    assert design_stamp.stale_templates(tmp_path) == ["story"]


def test_a_collage_the_old_sidecar_vouches_for_is_not_reported(tmp_path):
    from postroll.media.layout_sidecar import layout_sidecar_path, write_layout_sidecar

    _cache(tmp_path, "collage", "reel_scroll")
    write_layout_sidecar(layout_sidecar_path(tmp_path / "collage.png"), [])

    assert design_stamp.stale_templates(tmp_path) == []


def test_a_collage_the_old_sidecar_records_as_older_is_still_caught(tmp_path):
    # The one case the sidecar fallback still earns: #160 recorded a version, it
    # is behind, and there is no day stamp because the day has not been
    # regenerated since. That is evidence, and dropping it would throw away a
    # genuine detection the collage already had.
    from postroll.media.layout_sidecar import layout_sidecar_path, write_layout_sidecar

    _cache(tmp_path, "collage")
    write_layout_sidecar(layout_sidecar_path(tmp_path / "collage.png"), [], version=0)

    assert design_stamp.stale_templates(tmp_path) == ["collage"]


def test_a_collage_whose_sidecar_predates_the_stamp_is_not_reported(tmp_path):
    # A bare-array sidecar is one written before #160, so it records no version.
    # Same rule as everywhere else: no record is not evidence. This is the shape
    # every collage on disk is in today.
    from postroll.media.layout_sidecar import layout_sidecar_path

    _cache(tmp_path, "collage")
    layout_sidecar_path(tmp_path / "collage.png").write_text(json.dumps([]), encoding="utf-8")

    assert design_stamp.stale_templates(tmp_path) == []


def test_the_day_stamp_wins_over_the_collage_sidecar(tmp_path):
    # Once a day carries a stamp, that is the record. A sidecar left behind by a
    # newer partial write must not override what the day says about itself.
    from postroll.media.layout_sidecar import layout_sidecar_path, write_layout_sidecar

    _cache(tmp_path, "collage")
    write_layout_sidecar(layout_sidecar_path(tmp_path / "collage.png"), [])
    design_stamp.design_stamp_path(tmp_path).write_text(
        json.dumps({"templates": {"collage": 0}}), encoding="utf-8")

    assert design_stamp.stale_templates(tmp_path) == ["collage"]


def test_a_template_stamped_newer_than_this_build_is_not_stale(tmp_path):
    # An asset rendered by a newer build than the one reading it is not
    # something this app can improve by regenerating, and badging it would send
    # the person to rebuild a better asset with an older design.
    _cache(tmp_path, "story")
    design_stamp.design_stamp_path(tmp_path).write_text(
        json.dumps({"templates": {
            "story": tokens.MEDIA_DESIGN_VERSIONS["story"] + 5,
        }}), encoding="utf-8")
    assert design_stamp.stale_templates(tmp_path) == []


def test_a_stamped_template_with_no_asset_on_disk_is_not_reported(tmp_path):
    # There is nothing to regenerate and nothing rendering an old look, so
    # naming it would send the person after an asset that does not exist.
    design_stamp.design_stamp_path(tmp_path).write_text(
        json.dumps({"templates": {"story": 0}}), encoding="utf-8")
    assert design_stamp.stale_templates(tmp_path) == []


def test_a_file_carrying_no_design_is_not_reported(tmp_path):
    # Friday's cover_frame.jpg is a source photograph copied out of a temp dir.
    # Regenerating the day cannot make it look newer.
    (tmp_path / "cover_frame.jpg").write_bytes(b"x")
    assert design_stamp.stale_templates(tmp_path) == []
    assert design_stamp.cached_templates(tmp_path) == []


def test_an_empty_day_folder_has_nothing_to_say(tmp_path):
    assert design_stamp.cached_templates(tmp_path) == []
    assert design_stamp.stale_templates(tmp_path) == []


def test_a_missing_day_folder_does_not_raise(tmp_path):
    assert design_stamp.stale_templates(tmp_path / "never rendered") == []


def test_stale_templates_come_back_in_a_stable_order(tmp_path):
    # The badge names them, and a set's order would reword the message on every
    # read for no reason.
    _cache(tmp_path, "story", "collage", "before_after")
    design_stamp.design_stamp_path(tmp_path).write_text(
        json.dumps({"templates": {"story": 0, "collage": 0, "before_after": 0}}),
        encoding="utf-8")
    assert design_stamp.stale_templates(tmp_path) == [
        "before_after", "collage", "story"]


# ── what a run says it produced ───────────────────────────────────────────────

def test_the_templates_come_from_what_the_run_produced(tmp_path):
    # Not from a list each call site has to remember to append to. A payload
    # half built by a helper and half by its caller has nowhere its
    # completeness can be seen, so a missing entry is invisible to a reader of
    # either half (L94).
    day_result = {
        "reel": str(tmp_path / "reel_morph.mp4"),
        "story_cover": str(tmp_path / "before_after.png"),
    }
    assert design_stamp.rendered_templates(day_result, tmp_path) == [
        "before_after", "reel_morph"]


def test_an_asset_written_outside_the_day_folder_is_not_claimed(tmp_path):
    # Tuesday's before/after goes to a temp file on a final export, because it
    # is only the reel's closing frame there. Stamping the day for it would
    # claim a current asset the day folder does not hold.
    day_result = {"story_cover": "/tmp/xyz_tuesday_before_after.png"}
    assert design_stamp.rendered_templates(day_result, tmp_path) == []


def test_a_result_that_is_not_a_path_is_skipped(tmp_path):
    # friday_clip_plan and cover_pick are dicts sitting in the same result.
    day_result = {"friday_clip_plan": {"selections": []},
                  "cover_pick": {"source_path": "/a/b.jpg"},
                  "reel": str(tmp_path / "reel_clip.mp4")}
    assert design_stamp.rendered_templates(day_result, tmp_path) == ["reel_clip"]


# ── generate_media leaves one behind ──────────────────────────────────────────

def _day_folder(output_dir: Path, day: str) -> Path:
    from postroll.ai.generate_media import DAY_FOLDER_NAMES

    base = next(p for p in Path(output_dir).iterdir() if p.is_dir())
    return base / DAY_FOLDER_NAMES[day]


def _manifest(day: str, photo, **day_fields) -> dict:
    return {
        "event": "Test Event",
        "org": "Test Org",
        "venue": "Test Venue",
        "days": {day: {"photos": [str(photo)] * 4, **day_fields}},
    }


def test_a_rendered_day_says_which_design_made_it(tmp_output, sample_photo):
    from postroll.ai.generate_media import generate_media

    generate_media(_manifest("wednesday", sample_photo), tmp_output, static_only=True)

    assert design_stamp.read_design_stamp(_day_folder(tmp_output, "wednesday")) == {
        "collage": tokens.MEDIA_DESIGN_VERSIONS["collage"]
    }


def test_the_stamp_names_what_the_day_actually_rendered(tmp_output, sample_photo):
    # Not a fixed list per day: Tuesday's assets depend on which photos were
    # assigned and whether ffmpeg is there, so a stamp naming templates the day
    # never produced would badge the day for an asset that does not exist.
    from postroll.ai.generate_media import generate_media

    generate_media(
        _manifest("tuesday", sample_photo,
                  raw_photo=str(sample_photo), edited_photo=str(sample_photo)),
        tmp_output, static_only=True,
    )

    recorded = design_stamp.read_design_stamp(_day_folder(tmp_output, "tuesday"))
    assert "before_after" in recorded
    assert "reel_scroll" not in recorded


def test_a_freshly_rendered_day_is_not_stale(tmp_output, sample_photo):
    from postroll.ai.generate_media import generate_media

    generate_media(_manifest("wednesday", sample_photo), tmp_output, static_only=True)

    assert design_stamp.stale_templates(_day_folder(tmp_output, "wednesday")) == []


def test_a_final_export_leaves_no_stamp_in_the_upload_folder(tmp_output, sample_photo):
    # The export folder is what Dan uploads by hand. Staleness is a question
    # about the cached preview, which is the copy that survives to be rendered
    # again; a bookkeeping file among the assets is noise. The collage's layout
    # sidecar is suppressed on the same run for the same reason.
    from postroll.ai.generate_media import generate_media

    generate_media(_manifest("wednesday", sample_photo), tmp_output,
                   static_only=True, final_export=True)

    assert not design_stamp.design_stamp_path(
        _day_folder(tmp_output, "wednesday")).exists()


def test_a_day_that_rendered_nothing_leaves_no_stamp(tmp_output, sample_photo):
    # An empty stamp would claim the day is current, which is a stronger thing
    # to say than "there is nothing here".
    from postroll.ai.generate_media import generate_media

    manifest = _manifest("wednesday", sample_photo)
    manifest["days"]["wednesday"]["photos"] = []
    generate_media(manifest, tmp_output, static_only=True)

    day_dir = _day_folder(tmp_output, "wednesday")
    assert not design_stamp.design_stamp_path(day_dir).exists()


# ── the app reads the same file ───────────────────────────────────────────────

def test_the_shared_fixture_is_what_the_writer_actually_produces(tmp_path):
    # The Swift tests build their own JSON, and a fake you wrote can only
    # confirm your own assumption about the real format (L52). This fixture is
    # the one thing both sides read, so it has to be measured from the writer
    # rather than shaped by hand to make either side pass (L48). A version bump
    # fails here until the fixture is regenerated.
    fixture = REPO_ROOT / "tests" / "fixtures" / "design_stamp.json"

    design_stamp.write_design_stamp(tmp_path, tokens.MEDIA_DESIGN_VERSIONS.keys())
    produced = json.loads(
        design_stamp.design_stamp_path(tmp_path).read_text(encoding="utf-8"))

    committed = json.loads(fixture.read_text(encoding="utf-8"))
    assert committed["templates"] == produced["templates"], (
        "tests/fixtures/design_stamp.json no longer matches what "
        "write_design_stamp produces, so the app is being tested against a "
        "format Python does not write. Regenerate it.")



def test_swift_mirrors_every_declared_version():
    # Two tables in two languages with nothing forcing them to agree would make
    # every asset read stale, or none of them.
    # Comments stripped, or a commented-out table carrying the marker decides
    # what this reads (#436).
    text = swift_without_comments(SWIFT_TOKENS.read_text(encoding="utf-8"))
    marker = "static let mediaDesignVersions: [String: Int] = ["
    assert marker in text, (
        "DesignTokens.swift does not declare mediaDesignVersions, so the app "
        "cannot tell a stale reel or story from a current one")
    body = text.split(marker, 1)[1].split("]", 1)[0]
    mirrored = {
        name: int(value)
        for name, value in re.findall(r'"([a-z_]+)"\s*:\s*(\d+)', body)
    }
    assert mirrored == tokens.MEDIA_DESIGN_VERSIONS


def test_swift_mirrors_every_recorded_design_change():
    """Two tables in two languages, and the app runs the Swift one (#804).

    A date missing on the Swift side badges nothing for that template, which is
    exactly the silence #804 was filed about, while the Python suite stays
    green. A date that differs badges a different slice of the library on the
    two halves.
    """
    text = swift_without_comments(SWIFT_TOKENS.read_text(encoding="utf-8"))
    marker = "static let mediaDesignChanged: [String: String] = ["
    assert marker in text, (
        "DesignTokens.swift does not declare mediaDesignChanged, so the app "
        "badges nothing on an unstamped day and the whole existing library "
        "stays uncovered (#804)")
    body = text.split(marker, 1)[1].split("]", 1)[0]
    mirrored = dict(re.findall(r'"([a-z_]+)"\s*:\s*"(\d{4}-\d{2}-\d{2})"', body))
    assert mirrored == {name: entry.day
                        for name, entry in tokens.MEDIA_DESIGN_CHANGED.items()}


def test_swift_reads_the_file_date_rather_than_only_the_stamp():
    """Built is not wired (L3).

    The table above can be mirrored perfectly while nothing reads it, and the
    badge would go on firing only on a stamp. This asks that the staleness scan
    actually consults the file's modification date.
    """
    text = swift_without_comments(SWIFT_STAMP.read_text(encoding="utf-8"))

    assert "contentModificationDate" in text, (
        "DesignStamp.swift never reads an asset's modification date, so an "
        "unstamped asset older than its design change is badged by nothing "
        "(#804)")
    # The BODY of staleTemplates, cut at the next declaration. Searching
    # everything after the signature is satisfied by the definition of
    # predatesItsDesignChange, which sits below it: the mutation that replaces
    # the CALL with `return false` left this green (L135, caught by
    # check_guards on the first attempt at this guard).
    body = text.split("static func staleTemplates", 1)[1].split("static func", 1)[0]
    assert "predatesItsDesignChange(" in body, (
        "staleTemplates does not call the unstamped rule, so the date check "
        f"exists and decides nothing. Its body is: {body}")


def test_swift_uses_the_same_stamp_filename():
    text = SWIFT_STAMP.read_text(encoding="utf-8")
    assert f'"{design_stamp.STAMP_NAME}"' in text, (
        "DesignStamp.swift looks for a different filename than Python writes, "
        "so the app would read no stamp at all and badge every day")
