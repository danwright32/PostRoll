"""#471: Jamendo reports failure inside the body of an HTTP 200.

Every Jamendo response carries a `headers` envelope beside `results`, and that
envelope is where an invalid client id, an exhausted rate limit or a malformed
query is reported. The HTTP status is 200 and `results` is `[]`, so the client
read a failure as "nothing matched" and threw the message naming the cause
away (L23: map the other system's vocabulary at the boundary).

The consequences were both silent and both wrong in the same direction.
`fetch_audio` retried the empty answer three times and then blamed the tags,
telling Dan to try different ones for a problem no tag change can fix. The
music picker went through `fetch_audio_candidates`, which returned an empty
list with no retry at all, so an auth failure and a genuinely empty search
looked identical on screen.

Mapped once, in `_jamendo_json`, because that is the single place both search
paths already share. Everything downstream already handles `JamendoUnavailable`
correctly from the network-outage work in #93, so this reuses that contract
rather than adding a second one.
"""

from __future__ import annotations

import json
from unittest.mock import MagicMock

import pytest

from postroll.audio import (
    JamendoUnavailable,
    _search_tracks,
    _search_tracks_namesearch,
    fetch_audio,
    fetch_audio_candidates,
)


def _ok_track() -> dict:
    return {"id": 1, "name": "A", "artist_name": "B", "duration": 100,
            "audiodownload": "http://x/a.mp3", "audiodownload_allowed": True}


def _responding(payload: dict, calls: list | None = None):
    def fake(url, timeout=15):
        if calls is not None:
            calls.append(url)
        mock = MagicMock()
        mock.__enter__ = lambda s: s
        mock.__exit__ = MagicMock(return_value=False)
        mock.read.return_value = json.dumps(payload).encode()
        return mock
    return fake


def _failed(code=5, message="Your credits are exhausted"):
    return {"headers": {"status": "failed", "code": code,
                        "error_message": message, "warnings": "",
                        "results_count": 0},
            "results": []}


def _succeeded(results=None):
    return {"headers": {"status": "success", "code": 0, "error_message": "",
                        "warnings": "", "results_count": len(results or [])},
            "results": results if results is not None else [_ok_track()]}


# ── the envelope is read ──────────────────────────────────────────────────────

def test_a_failed_envelope_is_an_outage_not_an_empty_result(monkeypatch):
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_failed()))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable):
        _search_tracks("cinematic", "key")


def test_the_vendors_own_message_survives(monkeypatch):
    # "Try different tags" is useless advice for an exhausted rate limit. The
    # message naming the real cause was being discarded (L11).
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_failed(message="Your credits are exhausted")))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable, match="credits are exhausted"):
        _search_tracks("cinematic", "key")


def test_the_vendors_error_code_is_named(monkeypatch):
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_failed(code=5)))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable, match="5"):
        _search_tracks("cinematic", "key")


def test_a_nonzero_code_fails_even_when_the_status_word_is_missing(monkeypatch):
    # Two independent signals, either of which is enough. Depending on one
    # spelling is how a guard matches a remembered shape and misses the real one.
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding({"headers": {"code": 5,
                                                 "error_message": "bad client id"},
                                     "results": []}))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable, match="bad client id"):
        _search_tracks("cinematic", "key")


def test_a_successful_envelope_passes_straight_through(monkeypatch):
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_succeeded()))

    assert len(_search_tracks("cinematic", "key")) == 1


def test_a_successful_envelope_with_no_matches_is_still_an_empty_result(monkeypatch):
    # The whole point is telling these two apart: this one really did match
    # nothing, and must NOT become an outage.
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_succeeded(results=[])))

    assert _search_tracks("cinematic", "key") == []


def test_a_response_with_no_envelope_at_all_is_not_treated_as_failure(monkeypatch):
    # Absence of the envelope is not evidence of anything. Reading it as a
    # failure would turn every good answer into an outage.
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding({"results": [_ok_track()]}))

    assert len(_search_tracks("cinematic", "key")) == 1


def test_an_envelope_failure_is_not_retried(monkeypatch):
    # A wrong client id is wrong on every attempt. Retrying it spends the
    # rate limit the failure may already be about.
    calls: list[str] = []
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_failed(), calls))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable):
        _search_tracks("cinematic", "key")

    assert len(calls) == 1, "an authentication or quota failure is not transient"


# ── every caller downstream tells the two apart now ───────────────────────────

def test_fetch_audio_stops_blaming_the_tags(monkeypatch, tmp_path):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_failed(message="Your credits are exhausted")))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable, match="credits are exhausted"):
        fetch_audio(tags="cinematic", cache_dir=tmp_path)


def test_the_music_picker_no_longer_shows_an_empty_list_for_an_auth_failure(
        monkeypatch, tmp_path):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_failed(code=1, message="invalid client id")))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    with pytest.raises(JamendoUnavailable, match="invalid client id"):
        fetch_audio_candidates(tags="cinematic", cache_dir=tmp_path)


def test_the_per_piece_search_still_degrades_but_says_so(monkeypatch, capsys):
    # This one runs once per candidate query across a whole programme, so it
    # is deliberately best effort. It must still report, or a total outage is
    # indistinguishable from "no piece matched" (#93).
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(_failed(message="invalid client id")))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    assert _search_tracks_namesearch("Mahler", "key") == []
    assert "invalid client id" in capsys.readouterr().err
