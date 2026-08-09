"""#123: reading a duration from ffprobe must not crash on a failed probe.

`float(result.stdout.strip())` with no look at the return code raises
ValueError the moment ffprobe writes nothing, which it does for a truncated
recording, a codec it cannot open, or a path that has moved. The traceback that
comes out names a float conversion, so the real cause (an unreadable video) is
nowhere in the message Dan sees.

There were five of these across four files, each parsing the same output its
own way, and one of them already did it safely. So this is one helper rather
than five patches: the next probe added should not get to invent a sixth
answer to the same question.

The rule the helper encodes is L50: a value parsed from a subprocess never
feeds a comparison directly. A failed parse yields None, and each caller maps
None onto its own fail-safe rather than letting NaN quietly compare false
against every threshold.
"""

from __future__ import annotations

import subprocess

import pytest

from postroll.media.probe import probe_duration


class _Result:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


@pytest.fixture
def fake_run(monkeypatch):
    """Replace subprocess.run for the module under test."""
    calls = {}

    def install(result):
        def _run(cmd, *a, **kw):
            calls["cmd"] = cmd
            return result
        monkeypatch.setattr(subprocess, "run", _run)
        return calls

    return install


def test_a_good_probe_returns_the_duration(fake_run):
    fake_run(_Result(0, "36.4\n"))

    assert probe_duration("clip.mp4") == pytest.approx(36.4)


def test_a_failed_probe_returns_none_rather_than_raising(fake_run):
    # ffprobe exits non-zero and writes nothing on a file it cannot open.
    fake_run(_Result(1, "", "moov atom not found"))

    assert probe_duration("broken.mp4") is None


def test_empty_output_on_a_zero_exit_returns_none(fake_run):
    # A zero exit is not a promise that anything was printed: a container with
    # no duration in its metadata exits 0 with an empty stdout.
    fake_run(_Result(0, "\n"))

    assert probe_duration("no-duration.mp4") is None


def test_unparseable_output_returns_none(fake_run):
    # "N/A" is what ffprobe prints for a stream whose duration it cannot work
    # out, and float("N/A") is the crash this exists to stop.
    fake_run(_Result(0, "N/A\n"))

    assert probe_duration("weird.mp4") is None


def test_a_zero_duration_returns_none(fake_run):
    # Zero is not a usable length: every caller divides by it, trims to it, or
    # fades from it. Returning it would push the failure one step downstream
    # into arithmetic that cannot say what went wrong.
    fake_run(_Result(0, "0.0\n"))

    assert probe_duration("empty.mp4") is None


def test_a_negative_duration_returns_none(fake_run):
    fake_run(_Result(0, "-3\n"))

    assert probe_duration("nonsense.mp4") is None


def test_a_missing_ffprobe_returns_none_rather_than_raising(fake_run, monkeypatch):
    # ffmpeg_check covers the toolchain at startup, but a probe reached by
    # another route must not raise FileNotFoundError out of a render.
    def _boom(*a, **kw):
        raise FileNotFoundError("ffprobe")
    monkeypatch.setattr(subprocess, "run", _boom)

    assert probe_duration("clip.mp4") is None


def test_the_probe_asks_ffprobe_for_the_format_duration(fake_run):
    calls = fake_run(_Result(0, "10\n"))

    probe_duration("clip.mp4")

    assert calls["cmd"][0] == "ffprobe"
    assert "format=duration" in calls["cmd"]
    assert str(calls["cmd"][-1]) == "clip.mp4"


# ── the callers use it ────────────────────────────────────────────────────────

def test_the_screen_reel_reports_an_unreadable_recording_by_name(monkeypatch):
    # The whole point: the message names the file and says it could not be
    # read, instead of a ValueError about converting a string to a float.
    from postroll.media import generate_reel_screen as grs

    monkeypatch.setattr(grs, "probe_duration", lambda p: None)

    with pytest.raises(RuntimeError) as e:
        grs.get_video_duration("/tmp/screen-recording.mov")

    message = str(e.value)
    assert "screen-recording.mov" in message
    assert "float" not in message.lower(), (
        "the reason must be the unreadable video, not the conversion that "
        f"happened to fail: {message}"
    )


def test_the_screen_reel_still_returns_a_good_duration(monkeypatch):
    from postroll.media import generate_reel_screen as grs

    monkeypatch.setattr(grs, "probe_duration", lambda p: 42.5)

    assert grs.get_video_duration("/tmp/ok.mov") == pytest.approx(42.5)


def test_audio_duration_still_answers_none_for_an_unreadable_track(fake_run):
    # audio_fit had the only safe version of this, and its callers depend on
    # None meaning "fall back to the raw track". Folding it onto the shared
    # helper must not change that.
    from postroll.media.audio_fit import audio_duration

    fake_run(_Result(1, ""))

    assert audio_duration("missing.mp3") is None
