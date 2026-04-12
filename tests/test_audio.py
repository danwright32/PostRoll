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
