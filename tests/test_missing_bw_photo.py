"""A set-but-missing B&W photo is ONE named condition on every surface (#180).

The optional B&W after feeds two renders. The before/after graphic used to open
it unconditionally and die with a bare FileNotFoundError; the slider reel used
to check `exists()` and quietly fall back to the two-photo treatment, shipping a
plausible-looking file that was not the one asked for. Neither told anybody the
file was missing, and generate_media caught one as non-fatal and let the other
fail the day, which is a third behaviour for the same input.
"""

from __future__ import annotations

import pytest

from postroll.media.missing_media import MissingMediaError, require_present
from postroll.media.generate_before_after import generate_before_after
from postroll.media.generate_reel_slider import generate_reel_slider


def test_require_present_passes_an_unset_path_through():
    # Optional and unset is not missing: there is simply nothing referenced.
    assert require_present(None, "B&W photo") is None
    assert require_present("", "B&W photo") is None


def test_require_present_returns_a_file_that_exists(sample_photo):
    assert require_present(sample_photo, "B&W photo") == str(sample_photo)


def test_require_present_names_the_slot_and_the_file(tmp_path):
    gone = tmp_path / "bw.jpg"

    with pytest.raises(MissingMediaError) as exc:
        require_present(gone, "B&W photo")

    assert "B&W photo" in str(exc.value)
    assert str(gone) in str(exc.value)


def test_before_after_reports_a_missing_bw_by_name(sample_photo, tmp_output, tmp_path):
    gone = tmp_path / "bw.jpg"

    with pytest.raises(MissingMediaError) as exc:
        generate_before_after(
            raw_path=sample_photo,
            edit_path=sample_photo,
            output_path=str(tmp_output / "ba.png"),
            event_name="Test",
            org="Org",
            venue="Venue",
            bw_path=str(gone),
        )

    assert "B&W photo" in str(exc.value)


def test_slider_reel_refuses_rather_than_silently_dropping_the_bw(
    sample_photo, tmp_output, tmp_path
):
    gone = tmp_path / "bw.jpg"

    with pytest.raises(MissingMediaError) as exc:
        generate_reel_slider(
            raw_path=sample_photo,
            edit_path=sample_photo,
            # A real path so the check under test is what fails, not the audio
            # step (which would reach Jamendo).
            audio_path=str(sample_photo),
            output_path=str(tmp_output / "reel.mp4"),
            event_name="Test",
            org="Org",
            venue="Venue",
            bw_path=str(gone),
        )

    assert "B&W photo" in str(exc.value)
    assert not (tmp_output / "reel.mp4").exists(), (
        "a two-photo reel here would look exactly like success"
    )


# ── generate_media reports it the same way on both days ────────────────────

def _manifest(day: str, tmp_path, sample_photo, bw: str) -> dict:
    return {
        "event": "Greatest Hits",
        "org": "Org",
        "venue": "Hall",
        "days": {
            day: {
                "photos": [str(sample_photo)],
                "raw_photo": str(sample_photo),
                "edited_photo": str(sample_photo),
                "bw_photo": bw,
            }
        },
    }


@pytest.mark.parametrize("day", ["tuesday", "friday"])
def test_generate_media_reports_the_missing_bw_on_both_days(
    day, tmp_path, sample_photo, tmp_output
):
    from postroll.ai.generate_media import generate_media

    gone = tmp_path / "bw.jpg"
    results = generate_media(
        _manifest(day, tmp_path, sample_photo, str(gone)),
        tmp_output,
        static_only=True,
    )

    message = results["errors"].get(day)
    assert message, f"{day} reported nothing about a chosen file that is not there"
    assert "B&W photo" in message
    assert str(gone) in message


@pytest.mark.parametrize("day", ["tuesday", "friday"])
def test_a_missing_optional_bw_still_produces_the_days_graphics(
    day, tmp_path, sample_photo, tmp_output
):
    """The B&W photo is OPTIONAL. A missing one is reported, but it must not
    cost the day its output: that would make an optional input mandatory the
    moment it is chosen, which is not what optional means (Dan, 2026-08-07).

    The original defect was the reel SILENTLY dropping to two photos. Reporting
    it is the fix; refusing to render was an overcorrection."""
    from postroll.ai.generate_media import generate_media

    gone = tmp_path / "bw.jpg"
    results = generate_media(
        _manifest(day, tmp_path, sample_photo, str(gone)),
        tmp_output,
        static_only=True,
    )

    assert "B&W photo" in results["errors"].get(day, ""), "the missing file is still named"
    produced = results.get(day) or {}
    assert produced, f"{day} produced nothing because an OPTIONAL photo was missing"
    key = "story_cover" if day == "tuesday" else "before_after"
    assert key in produced, f"the two-photo {key} should still have been rendered"


@pytest.mark.parametrize("day", ["tuesday", "friday"])
def test_a_missing_REQUIRED_photo_does_block_the_day(
    day, tmp_path, sample_photo, tmp_output
):
    """The RAW and edited photos are not optional: there is no before/after to
    make without them, so a substitute would be a different post."""
    from postroll.ai.generate_media import generate_media

    gone = tmp_path / "raw.jpg"
    manifest = _manifest(day, tmp_path, sample_photo, "")
    manifest["days"][day]["raw_photo"] = str(gone)

    results = generate_media(manifest, tmp_output, static_only=True)

    assert "RAW photo" in results["errors"].get(day, "")
    produced = results.get(day) or {}
    for key in ("story_cover", "before_after", "reel"):
        assert key not in produced, f"{day} rendered a {key} without the RAW photo"


def test_the_style_falls_back_to_two_photo_when_the_bw_is_gone(tmp_path, sample_photo, tmp_output):
    """The 3-photo style is chosen from the B&W photo's presence. When that file
    is missing the style has to fall back too, or the style and the render
    disagree about which post this is."""
    from postroll.ai.generate_media import generate_media

    gone = tmp_path / "bw.jpg"
    results = generate_media(
        _manifest("tuesday", tmp_path, sample_photo, str(gone)),
        tmp_output, static_only=True,
    )

    assert "B&W photo" in results["errors"].get("tuesday", "")
    assert results.get("tuesday"), "the day still renders, in its two-photo form"


def test_style_decision_and_render_agree_on_a_present_bw(sample_photo):
    from postroll.ai.generate_media import resolve_tuesday_reel_style

    # The style picks 3-photo from bw alone. That is only safe because the
    # render now refuses a missing bw instead of quietly dropping to 2 photos.
    assert resolve_tuesday_reel_style(bw=str(sample_photo), requested="morph") == "slider"


def test_two_independent_failures_on_one_day_both_survive(
    monkeypatch, tmp_path, sample_photo, tmp_output
):
    """A day can fail for more than one reason at once. Each write to the day's
    error used to replace the last, so whichever check ran second silently
    erased the first: with no ffmpeg installed, the missing B&W photo vanished
    from the report entirely. Caught by CI, whose runners have no ffmpeg."""
    from postroll.ai.generate_media import generate_media

    monkeypatch.setattr("shutil.which", lambda name: None)   # no ffmpeg
    gone = tmp_path / "bw.jpg"

    results = generate_media(
        _manifest("tuesday", tmp_path, sample_photo, str(gone)),
        tmp_output,
        static_only=False,
    )

    message = results["errors"].get("tuesday", "")
    assert "B&W photo" in message, f"the missing photo was erased by the other failure: {message}"
    assert "ffmpeg" in message, f"the missing toolchain was erased by the other failure: {message}"
