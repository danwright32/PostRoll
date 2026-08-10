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
import re
from pathlib import Path

import pytest

from postroll.media import design_stamp
from postroll.media import design_tokens as tokens


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


def test_an_asset_with_no_record_is_not_reported(tmp_path):
    # The badge fires on evidence, never on the absence of it. Measured on real
    # data (2026-08-10): every one of the 66 day folders on Dan's machine holds
    # assets and no stamp, so treating "no record" as stale badged all 66 at
    # once, and a badge on every day is one nobody reads (L36). Those assets are
    # not even old: the gallery redesign landed 2026-07-14 and the newest
    # previews were rendered 2026-08-07.
    #
    # The cost is real and accepted: an asset genuinely older than the redesign
    # goes unreported. There are none on disk, and from here on every render
    # leaves a stamp, so a future design change is caught by evidence.
    _cache(tmp_path, "reel_scroll", "story", "collage")
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
    text = SWIFT_TOKENS.read_text(encoding="utf-8")
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


def test_swift_uses_the_same_stamp_filename():
    text = SWIFT_STAMP.read_text(encoding="utf-8")
    assert f'"{design_stamp.STAMP_NAME}"' in text, (
        "DesignStamp.swift looks for a different filename than Python writes, "
        "so the app would read no stamp at all and badge every day")
