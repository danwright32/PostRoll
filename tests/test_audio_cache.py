"""#111: the downloaded-track cache lives with the rest of the app's data and
is bounded.

Two separate defects. The cache sat at `~/.postroll/audio_cache`, a hidden
directory in the home folder, months after everything else the app writes moved
to `~/Library/Application Support/PostRoll`; and nothing ever deleted anything
from it, so re-rolling audio candidates grew it without limit, in a place Dan
would never think to look.

The clock is injected rather than read, so the age policy is asserted against a
fixed instant instead of against whatever `time.time()` happens to be during
the run.
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from postroll import audio
from postroll.data_root import data_root


DAY = 24 * 60 * 60


def _track(cache: Path, track_id: str, *, size: int, age_days: float, now: float) -> Path:
    path = cache / f"{track_id}.mp3"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x00" * size)
    stamp = now - age_days * DAY
    import os
    os.utime(path, (stamp, stamp))
    return path


# ── Where it lives ────────────────────────────────────────────────────────────

def test_cache_sits_under_the_data_root_the_app_exports(monkeypatch, tmp_path):
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))
    assert audio.default_cache_dir() == tmp_path / "audio_cache"


def test_cache_falls_back_to_application_support(monkeypatch, tmp_path):
    monkeypatch.delenv("POSTROLL_DATA_DIR", raising=False)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    assert audio.default_cache_dir() == (
        tmp_path / "Library" / "Application Support" / "PostRoll" / "audio_cache"
    )


def test_cache_is_no_longer_the_hidden_home_directory(monkeypatch, tmp_path):
    monkeypatch.delenv("POSTROLL_DATA_DIR", raising=False)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    assert audio.default_cache_dir() != tmp_path / ".postroll" / "audio_cache"


def test_the_data_root_is_the_one_the_usage_log_already_used(monkeypatch, tmp_path):
    # cap_signals and the usage log resolve the same root; the cache must not
    # become a fourth independent answer to the same question.
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))
    from postroll.ai.usage_log import default_log_path
    assert default_log_path().parent == data_root()
    assert audio.default_cache_dir().parent == data_root()


# ── Age policy ────────────────────────────────────────────────────────────────

def test_reclaims_tracks_older_than_the_age_cap(tmp_path):
    now = 1_800_000_000.0
    old = _track(tmp_path, "1", size=10, age_days=40, now=now)
    _track(tmp_path, "2", size=10, age_days=3, now=now)

    report = audio.prune_cache(tmp_path, max_age_days=30, now=now)

    assert not old.exists()
    assert (tmp_path / "2.mp3").exists()
    assert report["removed"] == ["1.mp3"]
    assert report["bytes"] == 10


def test_keeps_everything_inside_the_age_window(tmp_path):
    now = 1_800_000_000.0
    _track(tmp_path, "1", size=10, age_days=29.9, now=now)

    report = audio.prune_cache(tmp_path, max_age_days=30, now=now)

    assert (tmp_path / "1.mp3").exists()
    assert report["removed"] == []
    assert report["bytes"] == 0


# ── Size policy ───────────────────────────────────────────────────────────────

def test_reclaims_least_recently_used_first_when_over_the_size_cap(tmp_path):
    now = 1_800_000_000.0
    _track(tmp_path, "oldest", size=100, age_days=9, now=now)
    _track(tmp_path, "middle", size=100, age_days=5, now=now)
    _track(tmp_path, "newest", size=100, age_days=1, now=now)

    report = audio.prune_cache(tmp_path, max_age_days=365, max_bytes=250, now=now)

    assert not (tmp_path / "oldest.mp3").exists()
    assert (tmp_path / "middle.mp3").exists()
    assert (tmp_path / "newest.mp3").exists()
    assert report["removed"] == ["oldest.mp3"]
    assert report["bytes"] == 100


def test_stops_as_soon_as_it_is_under_the_cap(tmp_path):
    now = 1_800_000_000.0
    for i, age in enumerate([9, 5, 1]):
        _track(tmp_path, f"t{i}", size=100, age_days=age, now=now)

    report = audio.prune_cache(tmp_path, max_age_days=365, max_bytes=300, now=now)

    assert report["removed"] == []


# ── What it refuses to touch ──────────────────────────────────────────────────

def test_never_touches_a_file_it_did_not_write(tmp_path):
    now = 1_800_000_000.0
    _track(tmp_path, "1", size=10, age_days=90, now=now)
    stranger = tmp_path / "notes.txt"
    stranger.write_text("something a person put here")
    import os
    os.utime(stranger, (now - 90 * DAY, now - 90 * DAY))
    nested = tmp_path / "sub"
    nested.mkdir()

    audio.prune_cache(tmp_path, max_age_days=30, now=now)

    assert stranger.exists(), "prune reached outside the tracks it downloaded"
    assert nested.exists()


def test_a_missing_cache_directory_is_not_an_error(tmp_path):
    report = audio.prune_cache(tmp_path / "never-created", now=1_800_000_000.0)
    assert report == {"removed": [], "bytes": 0}


# ── The old location ──────────────────────────────────────────────────────────

def test_reclaims_the_legacy_home_directory_under_the_same_policy(tmp_path):
    now = 1_800_000_000.0
    legacy = tmp_path / "legacy" / "audio_cache"
    _track(legacy, "1", size=10, age_days=90, now=now)
    _track(legacy, "2", size=10, age_days=1, now=now)

    report = audio.prune_cache(
        tmp_path / "cache", max_age_days=30, now=now, legacy_dir=legacy
    )

    assert not (legacy / "1.mp3").exists()
    assert (legacy / "2.mp3").exists(), "a recent legacy track is still a valid cache hit"
    assert "1.mp3" in report["removed"]


def test_a_named_cache_dir_does_not_licence_a_sweep_of_the_home_folder(monkeypatch, tmp_path):
    # The first version of prune_cache swept LEGACY_CACHE_DIR on every call, so
    # running these very tests deleted the real cached tracks out of the home
    # folder. A caller that names its own directory is not asking for that.
    now = 1_800_000_000.0
    legacy = tmp_path / "home" / ".postroll" / "audio_cache"
    _track(legacy, "1", size=10, age_days=400, now=now)
    monkeypatch.setattr(audio, "LEGACY_CACHE_DIR", legacy)

    audio.prune_cache(tmp_path / "cache", max_age_days=30, now=now)

    assert (legacy / "1.mp3").exists()


def test_the_default_route_never_reaches_the_home_folder_from_a_test(monkeypatch, tmp_path):
    now = 1_800_000_000.0
    legacy = tmp_path / "home" / ".postroll" / "audio_cache"
    _track(legacy, "1", size=10, age_days=400, now=now)
    monkeypatch.setattr(audio, "LEGACY_CACHE_DIR", legacy)
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path / "data"))

    audio.prune_cache(max_age_days=30, now=now)

    assert (legacy / "1.mp3").exists(), (
        "a test run reached the real legacy path through the default argument"
    )


def test_removes_the_legacy_directory_once_it_is_empty(tmp_path):
    now = 1_800_000_000.0
    legacy = tmp_path / "legacy" / "audio_cache"
    _track(legacy, "1", size=10, age_days=90, now=now)

    audio.prune_cache(tmp_path / "cache", max_age_days=30, now=now, legacy_dir=legacy)

    assert not legacy.exists()


# ── It actually runs ──────────────────────────────────────────────────────────

def test_a_fetch_prunes_the_cache_it_just_wrote_to(monkeypatch, tmp_path):
    # A prune nothing calls is the same as no prune. This is the wiring, not
    # the policy: the policy is asserted above.
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    calls = []
    monkeypatch.setattr(
        audio, "prune_cache",
        lambda cache_dir=None, **kw: calls.append(Path(cache_dir)) or {"removed": [], "bytes": 0},
    )
    from unittest.mock import patch
    with patch("postroll.audio._search_tracks", return_value=[]):
        audio.fetch_audio_candidates("ambient", cache_dir=tmp_path)

    assert calls == [tmp_path]


def test_the_module_docstring_no_longer_advertises_the_old_location():
    assert ".postroll/audio_cache" not in (audio.__doc__ or ""), (
        "the docstring still sends a reader to the directory the cache left"
    )
