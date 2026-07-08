"""Tests for the shared music-bed resolution used by any day's reel render
(Phase 4, #135): a user-provided file wins outright, otherwise a fresh
Jamendo fetch using the same tag derivation swap_reel_audio.py already
reuses across days.
"""

from __future__ import annotations

from unittest.mock import patch

from postroll.ai.audio_tags import resolve_reel_audio


def test_user_provided_file_wins_without_fetching():
    with patch("postroll.ai.audio_tags.fetch_audio") as mock_fetch:
        result = resolve_reel_audio("/tmp/my_track.mp3", shoot_type="performance", pieces=[])

    assert result == "/tmp/my_track.mp3"
    mock_fetch.assert_not_called()


def test_no_file_fetches_from_jamendo_using_derived_tags():
    with patch("postroll.ai.audio_tags.fetch_audio", return_value="/cache/track.mp3") as mock_fetch:
        result = resolve_reel_audio(None, shoot_type="performance", pieces=[])

    assert result == "/cache/track.mp3"
    mock_fetch.assert_called_once()
