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
    ffmpeg_version_line,
    ffmpeg_versions,
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


# ── Which version produced a good render (#474) ───────────────────────────────
#
# The toolchain was presence-checked and never version-recorded, while the
# codebase has already measured version-dependent ffmpeg behaviour: audio_fit
# documents an acrossfade graph that exits 0 on CI's Linux build while writing a
# file ffprobe cannot read. So a brew upgrade is an unannounced behaviour change
# with nothing saying which version the last good render came from (L25).


def test_the_version_is_read_from_the_binary_that_will_do_the_work():
    """Measured against the real binaries rather than a stub, because a stub can
    only confirm our own assumption about what `ffmpeg -version` prints (L52)."""
    pytest.importorskip("shutil")
    import shutil as _shutil

    if not _shutil.which("ffmpeg"):
        pytest.skip("ffmpeg is not installed on this machine")

    versions = ffmpeg_versions()

    assert versions["ffmpeg"], f"could not read a version out of the real binary: {versions}"
    # A version, not the whole banner: the banner carries the build's clang
    # version and a copyright year, and a line that long buries the one fact.
    assert len(versions["ffmpeg"]) < 40, versions["ffmpeg"]
    assert "copyright" not in versions["ffmpeg"].lower()


def test_a_missing_binary_has_no_version_rather_than_a_made_up_one(monkeypatch):
    """The failure path. A version this could not read must read as unknown, not
    as a value, or the record it exists to keep says something it never measured
    (L11)."""
    monkeypatch.setattr("shutil.which", lambda name: None)

    versions = ffmpeg_versions()

    assert versions == {"ffmpeg": None, "ffprobe": None}


def test_an_unrunnable_binary_has_no_version_either(monkeypatch):
    """Present on PATH and refusing to run is a different failure from absent,
    and both have to come out as unknown rather than as an exception that stops
    a render this has no business stopping."""
    monkeypatch.setattr("shutil.which", lambda name: f"/x/{name}")

    def explode(*a, **k):
        raise OSError("Exec format error")

    monkeypatch.setattr("subprocess.run", explode)

    assert ffmpeg_versions() == {"ffmpeg": None, "ffprobe": None}


def test_the_line_the_run_records_names_the_version():
    line = ffmpeg_version_line({"ffmpeg": "8.1", "ffprobe": "8.1"})
    assert "8.1" in line
    assert "ffmpeg" in line


def test_the_line_says_so_when_the_version_could_not_be_read():
    """Silence here would be indistinguishable from a version that was recorded,
    which is the whole failure this record exists to prevent."""
    line = ffmpeg_version_line({"ffmpeg": None, "ffprobe": None})
    assert "8." not in line
    assert "unknown" in line.lower()


def test_the_run_records_which_toolchain_made_the_renders(
    monkeypatch, capsys, sample_photo, tmp_output
):
    """The record is only worth anything if a run actually leaves it, and it has
    to be left even on the run that has no ffmpeg at all: that run is exactly
    the one somebody will be reading the log of."""
    import postroll.ai.generate_media as gm

    monkeypatch.setattr("shutil.which", lambda name: None)

    manifest = {
        "event": "Concert", "org": "Org", "venue": "Hall",
        "days": {"thursday": {"photos": [str(sample_photo)]}},
    }
    gm.generate_media(manifest, tmp_output)

    out = capsys.readouterr().out
    assert "toolchain:" in out, "the run left no record of what rendered it"
    assert "unknown" in out
