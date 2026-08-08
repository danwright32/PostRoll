"""ffmpeg and ffprobe are hard runtime dependencies, so a missing one has to
say so once, clearly (#87).

Every reel goes through ffmpeg, and ffprobe reads durations. Neither is a Python
package, so nothing installs them and nothing declared them. The only check was
a per-call `shutil.which("ffmpeg")` whose failure printed a line to the log and
then produced a static image where a reel was asked for: the run "succeeded"
with the reels quietly missing. ffprobe was never checked at all, so a machine
with ffmpeg but not ffprobe failed deeper in, with a less useful message.
"""

from __future__ import annotations

import pytest

from postroll.media.ffmpeg_check import (
    FFmpegMissingError,
    ffmpeg_status,
    require_ffmpeg,
)


def test_reports_both_tools_present(monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: f"/usr/local/bin/{name}")

    status = ffmpeg_status()

    assert status.available
    assert status.missing == []
    assert status.message is None


def test_names_each_missing_tool_separately(monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: None if name == "ffprobe" else "/x/ffmpeg")

    status = ffmpeg_status()

    assert not status.available
    assert status.missing == ["ffprobe"], "ffprobe was never checked before"
    assert "ffprobe" in status.message


def test_the_message_carries_the_install_command(monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: None)

    status = ffmpeg_status()

    assert status.missing == ["ffmpeg", "ffprobe"]
    assert "brew install ffmpeg" in status.message, (
        "a message the user can act on, not just a statement that something is missing"
    )


def test_require_raises_rather_than_degrading_silently(monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: None)

    with pytest.raises(FFmpegMissingError) as exc:
        require_ffmpeg()

    assert "brew install ffmpeg" in str(exc.value)


def test_require_is_a_no_op_when_present(monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: f"/usr/local/bin/{name}")

    require_ffmpeg()  # must not raise


def test_generate_media_reports_the_missing_tool_instead_of_shipping_a_still(
    monkeypatch, tmp_path, sample_photo, tmp_output
):
    """A reel day with no ffmpeg used to print one log line and produce a story
    image, so the run read as a success with the reel simply absent."""
    import postroll.ai.generate_media as gm

    monkeypatch.setattr("shutil.which", lambda name: None)

    manifest = {
        "event": "Concert", "org": "Org", "venue": "Hall",
        "days": {"thursday": {"photos": [str(sample_photo)]}},
    }
    results = gm.generate_media(manifest, tmp_output)

    message = results["errors"].get("thursday", "")
    assert "ffmpeg" in message, f"nothing said the reel could not be made: {results['errors']}"
    assert "brew install ffmpeg" in message
