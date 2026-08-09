"""Tests for the Jamendo audio fetcher.

All HTTP calls are mocked so tests run offline without a real API key.
"""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from postroll.audio import fetch_audio, _search_tracks, JAMENDO_TRACKS_URL


# ===================================================================
# Helpers
# ===================================================================

FAKE_TRACK = {
    "id": 42,
    "name": "Test Track",
    "duration": 180,
    "audiodownload_allowed": True,
    "audiodownload": "https://example.com/track42.mp3",
}

FAKE_SEARCH_RESPONSE = {"results": [FAKE_TRACK]}
FAKE_MP3_BYTES = b"ID3" + b"\x00" * 128  # minimal fake MP3


def _mock_urlopen(response_data: dict):
    """Return a context-manager mock that yields the given JSON data."""
    mock = MagicMock()
    mock.__enter__ = lambda s: s
    mock.__exit__ = MagicMock(return_value=False)
    mock.read.return_value = json.dumps(response_data).encode()
    return mock


def _mock_download_urlopen():
    """Return a context-manager mock that yields fake MP3 bytes in chunks."""
    mock = MagicMock()
    mock.__enter__ = lambda s: s
    mock.__exit__ = MagicMock(return_value=False)
    mock.read.side_effect = [FAKE_MP3_BYTES, b""]
    return mock


# ===================================================================
# fetch_audio — environment / config
# ===================================================================


def test_raises_without_client_id(monkeypatch, tmp_path):
    monkeypatch.delenv("JAMENDO_CLIENT_ID", raising=False)
    with pytest.raises(EnvironmentError, match="JAMENDO_CLIENT_ID"):
        fetch_audio("ambient", cache_dir=tmp_path)


def test_raises_on_empty_results(monkeypatch, tmp_path):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    with patch("postroll.audio._search_tracks", return_value=[]):
        with pytest.raises(RuntimeError, match="No downloadable"):
            fetch_audio("nonexistent_genre", cache_dir=tmp_path)


# ===================================================================
# fetch_audio — download and cache
# ===================================================================


def test_downloads_track_on_first_call(monkeypatch, tmp_path):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")

    with patch("postroll.audio._search_tracks", return_value=[FAKE_TRACK]):
        with patch("postroll.audio._download") as mock_dl:
            result = fetch_audio("ambient", cache_dir=tmp_path, seed=0)

    mock_dl.assert_called_once()
    assert result == str(tmp_path / "42.mp3")


def test_skips_download_when_cached(monkeypatch, tmp_path):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    # Pre-create the cached file
    cached = tmp_path / "42.mp3"
    cached.write_bytes(FAKE_MP3_BYTES)

    with patch("postroll.audio._search_tracks", return_value=[FAKE_TRACK]):
        with patch("postroll.audio._download") as mock_dl:
            result = fetch_audio("ambient", cache_dir=tmp_path, seed=0)

    mock_dl.assert_not_called()
    assert result == str(cached)


def test_returns_path_string(monkeypatch, tmp_path):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")

    with patch("postroll.audio._search_tracks", return_value=[FAKE_TRACK]):
        with patch("postroll.audio._download"):
            result = fetch_audio("ambient", cache_dir=tmp_path, seed=0)

    assert isinstance(result, str)


def test_seed_gives_reproducible_selection(monkeypatch, tmp_path):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    tracks = [
        {**FAKE_TRACK, "id": i, "audiodownload": f"https://example.com/{i}.mp3"}
        for i in range(10)
    ]

    with patch("postroll.audio._search_tracks", return_value=tracks):
        with patch("postroll.audio._download"):
            r1 = fetch_audio("ambient", cache_dir=tmp_path, seed=7)
    with patch("postroll.audio._search_tracks", return_value=tracks):
        with patch("postroll.audio._download"):
            r2 = fetch_audio("ambient", cache_dir=tmp_path, seed=7)

    assert r1 == r2


# ===================================================================
# _search_tracks — URL construction
# ===================================================================


def test_search_tracks_includes_client_id():
    with patch("urllib.request.urlopen", return_value=_mock_urlopen(FAKE_SEARCH_RESPONSE)) as mock:
        _search_tracks("ambient", "myclientid")
    called_url = mock.call_args[0][0]
    assert "client_id=myclientid" in called_url
    assert called_url.startswith(JAMENDO_TRACKS_URL)


def test_search_tracks_filters_non_downloadable():
    no_download = {**FAKE_TRACK, "audiodownload_allowed": False, "audiodownload": ""}
    response = {"results": [no_download, FAKE_TRACK]}
    with patch("urllib.request.urlopen", return_value=_mock_urlopen(response)):
        tracks = _search_tracks("ambient", "key")
    assert len(tracks) == 1
    assert tracks[0]["id"] == FAKE_TRACK["id"]


def test_search_tracks_returns_empty_on_no_results():
    with patch("urllib.request.urlopen", return_value=_mock_urlopen({"results": []})):
        tracks = _search_tracks("nothing", "key")
    assert tracks == []


# ===================================================================
# _download — atomic cache writes
# ===================================================================


def test_download_writes_file_atomically(tmp_path):
    from postroll.audio import _download

    dest = tmp_path / "12345.mp3"
    with patch("urllib.request.urlopen", return_value=_mock_download_urlopen()):
        _download("https://example.com/track.mp3", dest)

    assert dest.read_bytes() == FAKE_MP3_BYTES
    # No temp debris left behind
    assert list(tmp_path.glob("*.part")) == []


def test_failed_download_leaves_no_file_at_cache_path(tmp_path):
    """A dropped connection must not leave a truncated file that later runs
    would treat as a valid cached track."""
    from postroll.audio import _download

    mock = MagicMock()
    mock.__enter__ = lambda s: s
    mock.__exit__ = MagicMock(return_value=False)
    mock.read.side_effect = [b"partial bytes", ConnectionResetError("dropped")]

    dest = tmp_path / "12345.mp3"
    with patch("urllib.request.urlopen", return_value=mock):
        with pytest.raises(ConnectionResetError):
            _download("https://example.com/track.mp3", dest)

    assert not dest.exists()
    assert list(tmp_path.glob("*.part")) == []


# ── #93: a Jamendo outage must not surface as a bare URLError ─────────────────
#
# `_search_tracks` called urlopen with no try/except while its sibling
# `_search_tracks_namesearch` wrapped the identical call, so a DNS failure or a
# 5xx during the tag path aborted a whole reel render with a raw Python
# traceback instead of the documented RuntimeError.

import urllib.error

from postroll.audio import (
    JamendoUnavailable, _search_tracks_namesearch, fetch_audio_candidates,
)


def _urlopen_raising(exc, calls):
    def fake(url, timeout=15):
        calls.append(url)
        raise exc
    return fake


@pytest.mark.parametrize("make_exc", [
    lambda: urllib.error.URLError("dns failure"),
    lambda: urllib.error.HTTPError("u", 503, "Service Unavailable", {}, None),
    lambda: TimeoutError("timed out"),
], ids=["urlerror", "http_503", "timeout"])
def test_search_tracks_raises_a_named_error_not_a_bare_urlerror(monkeypatch, make_exc):
    exc = make_exc()
    calls: list[str] = []
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _urlopen_raising(exc, calls))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable, match="music service"):
        _search_tracks("cinematic", "key")


def test_search_tracks_retries_a_transient_failure_before_giving_up(monkeypatch):
    calls: list[str] = []
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _urlopen_raising(urllib.error.URLError("blip"), calls))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable):
        _search_tracks("cinematic", "key")

    assert len(calls) > 1, "a single transient GET is worth retrying"


def test_search_tracks_recovers_when_the_retry_succeeds(monkeypatch):
    payload = {"results": [{"id": 1, "name": "A", "artist_name": "B",
                            "duration": 100, "audiodownload": "http://x/a.mp3",
                            "audiodownload_allowed": True}]}
    state = {"n": 0}

    def flaky(url, timeout=15):
        state["n"] += 1
        if state["n"] == 1:
            raise urllib.error.URLError("blip")
        return _mock_urlopen(payload)

    monkeypatch.setattr("postroll.audio.urllib.request.urlopen", flaky)
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    assert len(_search_tracks("cinematic", "key")) == 1


def test_a_jamendo_outage_is_a_runtime_error_callers_already_handle(monkeypatch):
    """JamendoUnavailable is a RuntimeError, so every existing caller that
    already catches the documented RuntimeError keeps working."""
    assert issubclass(JamendoUnavailable, RuntimeError)


def test_fetch_audio_surfaces_the_outage_rather_than_no_tracks_found(monkeypatch, tmp_path):
    """Distinct causes get distinct messages: 'could not reach' is not the
    same as 'nothing matched your tags', and only one of them is retryable."""
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _urlopen_raising(urllib.error.URLError("down"), []))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable, match="music service"):
        fetch_audio(tags="cinematic", cache_dir=tmp_path)


def test_fetch_audio_candidates_surfaces_the_outage_too(monkeypatch, tmp_path):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _urlopen_raising(urllib.error.URLError("down"), []))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable):
        fetch_audio_candidates(tags="cinematic", cache_dir=tmp_path)


def test_namesearch_degrades_to_empty_but_says_so(monkeypatch, capsys):
    """The program-match path runs many queries in a loop and is best effort,
    so it degrades. It must still report, or a total outage looks exactly like
    'no piece matched' and stays invisible."""
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _urlopen_raising(urllib.error.URLError("down"), []))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    assert _search_tracks_namesearch("Brahms", "key") == []
    assert "music service" in capsys.readouterr().err
