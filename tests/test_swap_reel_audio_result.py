"""What the audio swap reports back about the track it used (#262).

`reel`, `audio_source` and `tags` were all written and the app read none of
them: both call sites discarded the return value entirely, so the Jamendo track
that ended up in the reel was invisible in the app and the tags it was matched
on were lost the moment the run ended.

`tags` says WHAT THE TRACK WAS MATCHED ON. A user's own file was not matched on
anything, so it reports an empty string rather than a "user-provided" sentinel:
a sentinel means the app has to know one side's magic word to tell the two
cases apart, and a magic word shared across two languages by nothing but
memory is how the meaning drifts.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from postroll.ai import swap_reel_audio as mod


@pytest.fixture
def fake_reel(tmp_path: Path) -> Path:
    reel = tmp_path / "reel.mp4"
    reel.write_bytes(b"not really an mp4")
    return reel


@pytest.fixture
def stubbed(monkeypatch, tmp_path):
    """Everything outside this module's own decision-making, stubbed.

    The swap shells out to ffmpeg and reaches Jamendo over the network. Neither
    is what these assertions are about, and a test that needs either is a test
    that cannot run in CI (L2).
    """
    track = tmp_path / "jamendo_track.mp3"
    track.write_bytes(b"audio")

    monkeypatch.setattr(mod, "fetch_audio", lambda tags, seed=None: str(track))
    monkeypatch.setattr(mod, "_derive_audio_tags", lambda shoot_type, pieces: "strings,warm")
    monkeypatch.setattr(mod, "probe_duration", lambda p: 30.0)

    def fake_run(cmd, *a, **kw):
        # ffmpeg writes reel.swap.mp4, which the module then renames over the
        # original. Produce it so the rename does not fail.
        Path(cmd[-1]).write_bytes(b"swapped")
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(mod.subprocess, "run", fake_run)
    return track


def test_a_fetched_track_reports_the_tags_it_was_matched_on(fake_reel, stubbed):
    result = mod.swap_reel_audio(str(fake_reel), shoot_type="performance", pieces=[])
    assert result["tags"] == "strings,warm"
    assert result["audio_source"] == str(stubbed)
    assert result["reel"] == str(fake_reel.resolve())


def test_a_users_own_file_reports_no_tags_rather_than_a_sentinel(fake_reel, stubbed, tmp_path):
    # The failure this pins: a "user-provided" sentinel reads as a tag list to
    # anything that just displays the field, so the app would show Dan that his
    # own upload was "matched on user-provided".
    mine = tmp_path / "my_track.wav"
    mine.write_bytes(b"mine")

    result = mod.swap_reel_audio(
        str(fake_reel), shoot_type="performance", pieces=[], audio_file=str(mine)
    )
    assert result["tags"] == "", (
        "a user's own file was not matched on anything, so there are no tags to "
        f"report; got {result['tags']!r}"
    )
    assert result["audio_source"] == str(mine.resolve())


def test_it_reports_the_reel_it_actually_wrote(fake_reel, stubbed):
    # The app passes the reel path in and gets it back. Reporting what was
    # written rather than assuming it is what was asked for is the difference
    # between "it worked" and "it verifiably worked" (L12).
    result = mod.swap_reel_audio(str(fake_reel), shoot_type="performance", pieces=[])
    assert Path(result["reel"]).exists()
    assert Path(result["reel"]).read_bytes() == b"swapped"


def test_a_missing_audio_file_raises_rather_than_silently_fetching(fake_reel, stubbed, tmp_path):
    # Falling back to Jamendo here would swap in a stranger's music while
    # reporting success, and Dan asked for his own track.
    with pytest.raises(FileNotFoundError):
        mod.swap_reel_audio(
            str(fake_reel), shoot_type="performance", pieces=[],
            audio_file=str(tmp_path / "not_here.wav"),
        )
