"""Tests for fitting an audio track to an exact reel length.

The pure loop-planning helpers run anywhere; the end-to-end fits run ffmpeg and
are skipped when ffmpeg/ffprobe aren't on PATH.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

from postroll.media.audio_fit import (
    DEFAULT_CROSSFADE,
    _loop_copies,
    _loop_command,
    _loop_filtergraph,
    audio_duration,
    fit_audio_to_duration,
)

# One shared gate (#106): POSTROLL_REQUIRE_FFMPEG=1 turns a silent skip into
# a loud failure, which is what CI needs.
from conftest import HAVE_FFMPEG, needs_ffmpeg  # noqa: F401


# ===================================================================
# Pure loop planning
# ===================================================================

def test_loop_copies_covers_target_duration():
    # 10s clip, 1s crossfade, want 46s: each extra copy adds 9s of new audio.
    copies = _loop_copies(audio_len=10.0, duration=46.0, crossfade=1.0)
    # N copies span N*10 - (N-1)*1 seconds; that must reach 46.
    assert copies * 10 - (copies - 1) * 1 >= 46
    # ...and it shouldn't be wildly oversized (one copy of headroom is enough).
    assert (copies - 1) * 10 - (copies - 2) * 1 < 46 + 10


def test_loop_copies_minimum_two():
    # Even a clip nearly as long as the target needs at least two copies to
    # crossfade against.
    assert _loop_copies(audio_len=9.0, duration=10.0, crossfade=1.0) >= 2


def test_default_crossfade_is_short_and_equal_power():
    # A long linear blend of a track against its own start sounded like two
    # takes at once; the seam is now a short, equal-power crossfade.
    assert DEFAULT_CROSSFADE == 0.5
    graph = _loop_filtergraph(copies=2, crossfade=DEFAULT_CROSSFADE, duration=20.0)
    assert "acrossfade=d=0.500:c1=qsin:c2=qsin" in graph


def test_loop_filtergraph_structure():
    graph = _loop_filtergraph(copies=3, crossfade=1.0, duration=46.0)
    # Each copy is its own input, never branches of one asplit: sharing a
    # decoder across an acrossfade is what broke on the Linux ffmpeg.
    assert "asplit" not in graph
    assert "[0:a][1:a]" in graph and "[2:a]" in graph
    # Two crossfade joins for three copies, with an equal-power curve.
    assert graph.count("acrossfade=") == 2
    assert "c1=qsin:c2=qsin" in graph
    # Trimmed to the exact target, exposed as [aout].
    assert "atrim=0:46.000[aout]" in graph


def test_the_loop_command_passes_the_source_once_per_copy():
    """The graph references [0:a] through [N-1:a], so the command has to supply
    that many inputs or ffmpeg fails on a stream that was never opened."""
    cmd = _loop_command("/tmp/a.wav", "/tmp/out.wav", copies=3,
                        graph=_loop_filtergraph(3, 1.0, 46.0), duration=46.0)
    assert cmd.count("-i") == 3
    assert cmd.count("/tmp/a.wav") == 3
    assert cmd[-1] == "/tmp/out.wav"
    assert "[aout]" in cmd


def test_the_input_count_always_matches_the_graph():
    for copies in (2, 3, 5, 8):
        graph = _loop_filtergraph(copies, 0.5, 30.0)
        cmd = _loop_command("/s.wav", "/o.wav", copies=copies, graph=graph,
                            duration=30.0)
        highest = max(int(t.split(":")[0]) for t in graph.split("[")
                      if t[:1].isdigit() and ":a]" in t)
        assert cmd.count("-i") == highest + 1, copies


# ===================================================================
# End-to-end fits (ffmpeg)
# ===================================================================

def _make_tone(path: Path, *, seconds: float, freq: int = 440) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"sine=frequency={freq}:duration={seconds}", str(path)],
        check=True,
    )


def _mean_volume_db(path: Path, start: float, end: float) -> float:
    """mean_volume (dBFS) of [start, end] in `path`; -91 dB ≈ digital silence."""
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-ss", str(start), "-to", str(end),
         "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    match = re.search(r"mean_volume:\s*(-?\d+(?:\.\d+)?) dB", proc.stderr)
    assert match, f"no mean_volume in ffmpeg output: {proc.stderr[-300:]}"
    return float(match.group(1))


@needs_ffmpeg
def test_short_audio_is_looped_not_silence_padded(tmp_path):
    # A 3s tone fit to 12s must fill the whole 12s with sound, not stop at 3s.
    src = tmp_path / "short.wav"
    out = tmp_path / "fit.wav"
    _make_tone(src, seconds=3.0)

    fit_audio_to_duration(src, out, duration=12.0, crossfade=1.0)

    assert abs((audio_duration(out) or 0) - 12.0) < 0.2
    # The tail (well past the 3s source) is still audible — proof of looping.
    assert _mean_volume_db(out, 9.0, 11.5) > -40.0


@needs_ffmpeg
def test_long_audio_is_trimmed(tmp_path):
    src = tmp_path / "long.wav"
    out = tmp_path / "fit.wav"
    _make_tone(src, seconds=30.0)

    fit_audio_to_duration(src, out, duration=10.0)

    assert abs((audio_duration(out) or 0) - 10.0) < 0.2


@needs_ffmpeg
def test_unreadable_source_raises(tmp_path):
    bad = tmp_path / "not-audio.wav"
    bad.write_bytes(b"garbage")
    out = tmp_path / "fit.wav"

    with pytest.raises(RuntimeError):
        fit_audio_to_duration(bad, out, duration=10.0)


# ── An exit code is not proof of output ───────────────────────────────────────
#
# Found by CI once #106 stopped these tests skipping silently: on the Linux
# ffmpeg the crossfaded loop graph exits 0 and writes a file ffprobe cannot
# read. Success was claimed from the exit code alone, so a reel would have
# shipped with broken audio and nothing would have said so.


def test_a_zero_exit_that_produced_nothing_is_not_success(tmp_path, monkeypatch):
    """The failure mode CI caught: ffmpeg says fine, the file is not."""
    src = tmp_path / "src.wav"
    out = tmp_path / "out.wav"
    src.write_bytes(b"not really audio")

    # Source probes as short, so the loop path is taken; every ffmpeg call
    # "succeeds" and writes nothing.
    monkeypatch.setattr("postroll.media.audio_fit.audio_duration",
                        lambda p: 3.0 if str(p) == str(src) else None)
    monkeypatch.setattr("postroll.media.audio_fit._run", lambda cmd: True)

    with pytest.raises(RuntimeError, match="Could not fit audio"):
        fit_audio_to_duration(src, out, duration=12.0, crossfade=1.0)


def test_an_unreadable_loop_result_falls_back_to_the_trim(tmp_path, monkeypatch):
    """The loop graph failing must degrade to the plain trim, not to an error,
    because the trim still produces usable audio."""
    src = tmp_path / "src.wav"
    out = tmp_path / "out.wav"
    src.write_bytes(b"x")

    calls: list[str] = []

    def fake_run(cmd):
        calls.append("loop" if "-filter_complex" in cmd else "trim")
        return True

    def fake_duration(p):
        if str(p) == str(src):
            return 3.0
        # Unreadable after the loop attempt, readable after the trim.
        return 12.0 if "trim" in calls else None

    monkeypatch.setattr("postroll.media.audio_fit._run", fake_run)
    monkeypatch.setattr("postroll.media.audio_fit.audio_duration", fake_duration)

    assert fit_audio_to_duration(src, out, duration=12.0, crossfade=1.0) == str(out)
    assert calls == ["loop", "trim"], calls


# ===================================================================
# Saying that the music had to repeat (#1076)
# ===================================================================
#
# Looping was silent. A reel whose music repeats was indistinguishable from one
# whose track fits, and Dan found out only because he happened to know a track's
# length: Battery Dance Festival's is 53.3 seconds and its 50 second scroll is a
# 56 second video, so that reel was already being extended. He would have made a
# different decision with the fact in front of him.
#
# Raised from here rather than recomputed by each caller, so the sentence and
# the thing it describes cannot disagree (L107).

@needs_ffmpeg
def test_a_track_shorter_than_the_reel_says_it_had_to_repeat(tmp_path):
    src = tmp_path / "short.wav"
    _make_tone(src, seconds=3.0)
    said: list[str] = []

    fit_audio_to_duration(src, tmp_path / "fit.wav", duration=12.0,
                          crossfade=1.0, on_warning=said.append)

    assert len(said) == 1, said
    message = said[0]
    # The two lengths and the consequence. A sentence saying only that
    # something happened sends Dan to measure the track himself, which is the
    # step this exists to remove (L80).
    assert "3" in message and "12" in message, message
    assert "repeat" in message.lower(), message


@needs_ffmpeg
def test_a_track_that_covers_the_reel_says_nothing(tmp_path):
    """A warning on the ordinary outcome is one nobody reads (L36)."""
    src = tmp_path / "long.wav"
    _make_tone(src, seconds=30.0)
    said: list[str] = []

    fit_audio_to_duration(src, tmp_path / "fit.wav", duration=10.0,
                          on_warning=said.append)

    assert said == []


@needs_ffmpeg
def test_the_loop_is_still_reported_when_the_loop_graph_fails(tmp_path, monkeypatch):
    """The failure path, and the one that matters most.

    When the crossfade graph fails, the trim/pad fallback silently pads with
    SILENCE rather than looping, so the reel ends in nothing. That is a worse
    outcome than a repeat and the least likely to be noticed, so it must not be
    the one case that says nothing (L47).
    """
    import postroll.media.audio_fit as fit_mod

    real_run = fit_mod._run
    intercepted: list[list[str]] = []

    def fail_the_loop(cmd):
        # The exact argument, not a substring of it: `-filter_complex` is one
        # element of the list, and matching "filter_complex" catches nothing,
        # so the double silently becomes no double and the real loop runs
        # (L143). Asserted below rather than assumed.
        if "-filter_complex" in cmd:
            intercepted.append(cmd)
            return False
        return real_run(cmd)

    monkeypatch.setattr(fit_mod, "_run", fail_the_loop)

    src = tmp_path / "short.wav"
    _make_tone(src, seconds=3.0)
    said: list[str] = []

    fit_audio_to_duration(src, tmp_path / "fit.wav", duration=12.0,
                          crossfade=1.0, on_warning=said.append)

    assert intercepted, "the loop command was never intercepted, so nothing failed"
    assert said, "the fallback padded with silence and said nothing about it"
    assert any("silence" in m.lower() for m in said), said


def test_fitting_without_a_warning_hook_still_works(tmp_path):
    """Every caller that has no warnings channel passes nothing, so the
    default has to be a no-op rather than a required argument."""
    import inspect

    signature = inspect.signature(fit_audio_to_duration)
    assert signature.parameters["on_warning"].default is None
