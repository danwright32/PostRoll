"""#265: generate_media reports a failure and a warning as different facts.

`errors` used to carry two things that need opposite responses: a day that
could not render at all (ffmpeg died, a required photo gone) and a day that
rendered perfectly well with an OPTIONAL input missing. A consumer reading
`errors["tuesday"]` could not tell "Tuesday has no graphics" from "Tuesday is
fine, its B&W photo has moved" (L53).

It had already cost something. The export path wired `errors` up in #262 and
the first honest reader claimed a day's graphics were missing while they sat in
the folder, then suppressed the Exported milestone and the manifest for a
complete export. The workaround was to treat an entry as a failure only when
the day produced no assets, which reads a day that genuinely failed AND wrote
one stray file as fine.

`generate_week` already keeps the two apart. This makes `generate_media` agree.
"""

from __future__ import annotations

import pytest


def _manifest(day: str, tmp_path, photo, bw: str) -> dict:
    return {
        "event": "Test Event",
        "org": "Test Org",
        "venue": "Test Venue",
        "days": {
            day: {
                "raw_photo": str(photo),
                "edited_photo": str(photo),
                "bw_photo": bw,
            }
        },
    }


@pytest.mark.parametrize("day", ["tuesday", "friday"])
def test_a_missing_optional_photo_is_a_warning_not_a_failure(
    day, tmp_path, sample_photo, tmp_output
):
    from postroll.ai.generate_media import generate_media

    gone = tmp_path / "bw.jpg"
    results = generate_media(
        _manifest(day, tmp_path, sample_photo, str(gone)), tmp_output, static_only=True
    )

    assert "B&W photo" in results["warnings"].get(day, ""), (
        "the missing optional photo must still be named"
    )
    assert str(gone) in results["warnings"][day]
    assert day not in results["errors"], (
        "a day that rendered is not a failure, whatever was missing from it"
    )


@pytest.mark.parametrize("day", ["tuesday", "friday"])
def test_a_missing_required_photo_stays_a_failure(day, tmp_path, sample_photo, tmp_output):
    from postroll.ai.generate_media import generate_media

    gone = tmp_path / "raw.jpg"
    manifest = _manifest(day, tmp_path, sample_photo, "")
    manifest["days"][day]["raw_photo"] = str(gone)

    results = generate_media(manifest, tmp_output, static_only=True)

    assert "RAW photo" in results["errors"].get(day, "")
    assert day not in results["warnings"]


def test_a_failure_and_a_warning_on_one_day_are_reported_separately(
    monkeypatch, tmp_path, sample_photo, tmp_output
):
    """The case the old shared field could not express: Tuesday's B&W photo has
    moved AND ffmpeg is not installed. One of those blocks the day and one does
    not, and they used to arrive concatenated in one string."""
    from postroll.ai.generate_media import generate_media

    monkeypatch.setattr("shutil.which", lambda name: None)   # no ffmpeg
    gone = tmp_path / "bw.jpg"

    results = generate_media(
        _manifest("tuesday", tmp_path, sample_photo, str(gone)), tmp_output, static_only=False
    )

    assert "ffmpeg" in results["errors"].get("tuesday", "")
    assert "B&W photo" not in results["errors"].get("tuesday", ""), (
        "the optional photo is still filed as a failure"
    )
    assert "B&W photo" in results["warnings"].get("tuesday", "")


def test_warnings_is_always_present_even_when_there_are_none(
    tmp_path, sample_photo, tmp_output
):
    # A key that only appears when it is non-empty makes every reader write the
    # same defaulting, and one of them forgets.
    from postroll.ai.generate_media import generate_media

    results = generate_media(
        _manifest("friday", tmp_path, sample_photo, ""), tmp_output, static_only=True
    )

    assert results["warnings"] == {}


def test_two_warnings_on_one_day_both_survive(tmp_path, sample_photo, tmp_output):
    """Same rule `_record_error` already follows: a second note appends rather
    than replacing, or whichever ran last is the only one reported."""
    from postroll.ai.generate_media import _record_warning

    warnings: dict = {}
    _record_warning(warnings, "tuesday", "first thing")
    _record_warning(warnings, "tuesday", "second thing")
    _record_warning(warnings, "tuesday", "first thing")

    assert warnings["tuesday"] == "first thing; second thing"
