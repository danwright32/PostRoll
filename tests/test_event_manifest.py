"""#213: turn a stored event back into the manifest the app sends Python.

Running any `postroll.ai` module against a REAL past event means rebuilding the
manifest `PythonBridge` builds in Swift. Doing that by hand went wrong on the
first attempt in a way worth encoding: the store keeps photo paths as
percent-encoded `file://` URLs and the bridge sends `$0.path`, so reading the
stored value as a path finds nothing on disk and looks exactly like an event
whose media has been reclaimed. Every one of nineteen events reported as having
no photos left, which was wrong about all of them.

The store is passed in rather than found, so nothing here reads Dan's real
events file (L2).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools import event_manifest as em


REPO_ROOT = Path(__file__).resolve().parent.parent


def _store(tmp_path, **overrides):
    event = {
        "name": "BLUDLINE",
        "org": "An Org",
        "venue": "A Theater",
        "venueContext": "downstairs",
        # Foundation reference date: seconds since 2001-01-01 UTC, not Unix.
        "date": 807_235_200.0,
        "shootType": "Photo Call",
        "eventURL": "https://example.com/show",
        "ocrResult": {"performers": ["A Performer"]},
        "blogPhotoPaths": [],
        "days": {},
    }
    event.update(overrides)
    path = tmp_path / "events.json"
    path.write_text(json.dumps([event]), encoding="utf-8")
    return path


def test_a_stored_file_url_becomes_the_path_the_bridge_sends(tmp_path):
    # The trap. The store keeps absoluteString; PythonBridge sends `$0.path`.
    photo = tmp_path / "Home'r Bust! (Geffen Hall) -81.jpg"
    photo.write_bytes(b"x")
    url = ("file://" + str(photo).replace(" ", "%20").replace("'", "%27")
           .replace("!", "%21"))
    store = _store(tmp_path, days={"sunday": {"photoPaths": [url]}})

    manifest = em.build(store, "BLUDLINE")

    assert manifest["days"]["sunday"]["photos"] == [str(photo)]


def test_a_plain_path_is_left_alone(tmp_path):
    store = _store(tmp_path, days={"sunday": {"photoPaths": ["/tmp/a.jpg"]}})

    assert em.build(store, "BLUDLINE")["days"]["sunday"]["photos"] == ["/tmp/a.jpg"]


def test_the_stored_date_is_read_as_a_reference_date_not_a_unix_one(tmp_path):
    # 807235200 seconds after 2001-01-01 is 2026-08-01. Read as Unix epoch it
    # would be 1995, and every date-derived line in the output would be wrong.
    store = _store(tmp_path, days={"sunday": {"photoPaths": ["/tmp/a.jpg"]}})

    assert em.build(store, "BLUDLINE")["date"] == "2026-08-01"


@pytest.mark.parametrize("stored,expected", [
    ("Performance", "performance"),
    ("Photo Call", "photo_call"),
    ("Rehearsal", "rehearsal"),
    ("Combo", "rehearsal_and_performance"),
])
def test_the_shoot_type_matches_what_the_app_sends(tmp_path, stored, expected):
    # The generators write different prose depending on what Dan actually
    # witnessed, so a wrong value here produces a post about an evening that
    # did not happen.
    store = _store(tmp_path, shootType=stored,
                   days={"sunday": {"photoPaths": ["/tmp/a.jpg"]}})

    assert em.build(store, "BLUDLINE")["shoot_type"] == expected


def test_an_unknown_shoot_type_is_refused_rather_than_defaulted(tmp_path):
    # Quietly falling back to "performance" would tell the generators Dan shot
    # the whole show when the store says something nobody has mapped.
    store = _store(tmp_path, shootType="Dress Rehearsal Only",
                   days={"sunday": {"photoPaths": ["/tmp/a.jpg"]}})

    with pytest.raises(ValueError, match="Dress Rehearsal Only"):
        em.build(store, "BLUDLINE")


def test_the_shoot_type_table_matches_the_swift_it_mirrors():
    """Derived from Event.swift, not maintained beside it (L41).

    Two spellings live in that file and they are NOT the same: the enum's raw
    values are what the store holds ("Performance", "Combo"), and pythonValue is
    what the bridge sends ("performance", "rehearsal_and_performance"). The
    first draft of the table here guessed the keys from the case NAMES, which
    silently turned every Combo shoot into a full show.
    """
    import re

    source = (REPO_ROOT / "PostRollApp" / "Sources" / "Models" / "Event.swift"
              ).read_text(encoding="utf-8")
    enum = source.split("enum ShootType", 1)[1]
    raw_values = dict(re.findall(r'case (\w+)\s*=\s*"([^"]+)"', enum.split("var ")[0]))
    python_block = enum.split("var pythonValue", 1)[1].split("}", 2)[0]
    python_values = dict(re.findall(r'case \.(\w+):\s*return "([^"]+)"', python_block))

    assert raw_values, "no shoot type cases parsed out of Event.swift"
    assert set(raw_values) == set(python_values), (
        "Event.swift declares a shoot type with no pythonValue, or the other "
        "way round, so the mapping below cannot be complete")

    expected = {raw: python_values[case] for case, raw in raw_values.items()}
    assert em.SHOOT_TYPES == expected, (
        f"the shoot types this sends have drifted from the app's. "
        f"Swift says {expected}, tools/event_manifest.py says {em.SHOOT_TYPES}")


def test_a_day_with_no_photos_is_left_out(tmp_path):
    store = _store(tmp_path, days={"sunday": {"photoPaths": ["/tmp/a.jpg"]},
                                   "monday": {"photoPaths": []}})

    assert sorted(em.build(store, "BLUDLINE")["days"]) == ["sunday"]


def test_photo_tags_are_rekeyed_by_path_so_python_can_match_them(tmp_path):
    photo = tmp_path / "a photo.jpg"
    photo.write_bytes(b"x")
    url = "file://" + str(photo).replace(" ", "%20")
    store = _store(tmp_path, days={"wednesday": {
        "photoPaths": [url], "photoTags": {url: ["Someone"], "other": []}}})

    tags = em.build(store, "BLUDLINE")["days"]["wednesday"]["photo_tags"]

    assert tags == {str(photo): ["Someone"]}


def test_an_event_that_is_not_in_the_store_is_an_error(tmp_path):
    # Returning an empty manifest would run a whole week against nothing and
    # bill for it, which looks like a quiet event rather than a wrong name.
    store = _store(tmp_path)

    with pytest.raises(KeyError, match="Nobody"):
        em.build(store, "Nobody")


def test_an_event_whose_media_has_been_reclaimed_is_reported(tmp_path):
    # Most stored events have had their photos cleaned up. Building a manifest
    # pointing at files that are gone would fail deep inside a paid run.
    store = _store(tmp_path, days={"sunday": {"photoPaths": ["/tmp/gone-abc.jpg"]}})

    manifest = em.build(store, "BLUDLINE")

    assert em.missing_media(manifest) == ["/tmp/gone-abc.jpg"]


def test_an_event_whose_media_is_present_reports_nothing_missing(tmp_path):
    photo = tmp_path / "here.jpg"
    photo.write_bytes(b"x")
    store = _store(tmp_path, days={"sunday": {"photoPaths": [str(photo)]}})

    assert em.missing_media(em.build(store, "BLUDLINE")) == []


def test_the_files_counted_are_the_same_files_checked_for(tmp_path):
    """One predicate behind the count and the rows it promises (L16).

    The listing showed a day photo count beside a missing count that also
    included blog photos, so an event with 39 day photos and 12 blog photos read
    as "39 photos, 51 missing": more missing than it has. The number a person
    uses to judge an event has to be the same population the verdict is about.
    """
    photo = tmp_path / "kept.jpg"
    photo.write_bytes(b"x")
    store = _store(tmp_path,
                   days={"sunday": {"photoPaths": [str(photo), "/tmp/gone-1.jpg"]}},
                   blogPhotoPaths=["/tmp/gone-2.jpg"])
    manifest = em.build(store, "BLUDLINE")

    assert em.referenced_media(manifest) == [str(photo), "/tmp/gone-1.jpg",
                                             "/tmp/gone-2.jpg"]
    assert len(em.missing_media(manifest)) <= len(em.referenced_media(manifest))


def test_the_listing_never_reports_more_missing_than_it_counted(tmp_path):
    photo = tmp_path / "kept.jpg"
    photo.write_bytes(b"x")
    store = _store(tmp_path,
                   days={"sunday": {"photoPaths": [str(photo), "/tmp/gone-1.jpg"]}},
                   blogPhotoPaths=["/tmp/gone-2.jpg"])

    line = em.describe(em.build(store, "BLUDLINE"))

    assert "3 files" in line, line
    assert "2 missing" in line, line


def test_an_event_with_everything_on_disk_says_so_plainly(tmp_path):
    photo = tmp_path / "kept.jpg"
    photo.write_bytes(b"x")
    store = _store(tmp_path, days={"sunday": {"photoPaths": [str(photo)]}})

    assert "all media present" in em.describe(em.build(store, "BLUDLINE"))


def test_an_event_with_nothing_left_is_named_as_reclaimed(tmp_path):
    store = _store(tmp_path, days={"sunday": {"photoPaths": ["/tmp/gone.jpg"]}})

    assert "media reclaimed" in em.describe(em.build(store, "BLUDLINE"))


def test_the_event_names_the_store_holds_can_be_listed(tmp_path):
    store = _store(tmp_path)

    assert em.event_names(store) == ["BLUDLINE"]
