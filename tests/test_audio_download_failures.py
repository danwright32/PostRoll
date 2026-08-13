"""#450 and #453: a fallback to generic music must not look like a clean run.

Two silent `except Exception` sites, one in each direction.

The candidate fetchers dropped every download that failed and returned whatever
survived, so three of six candidates presented as a complete answer, and six of
six failing returned an empty list that is indistinguishable from nothing having
matched. A batch has to record the attempt on the items it failed, or the work
is silently paid for again and the partial result reports as a clean run (L47).

The Thursday reel's program-matched audio degraded to generic tag music on a
bare `except Exception`, with no line on stderr and no entry in the warnings
channel the pipeline has carried since #265. `audio.py` built a distinct
`JamendoUnavailable` type precisely so callers could tell an outage from a
programme nothing matched, and that caller erased the distinction.
"""

from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import pytest

from postroll.audio import (
    JamendoUnavailable,
    fetch_audio_candidates,
    fetch_program_audio_candidates,
)


TRACKS = [
    {
        "id": 100 + n,
        "name": f"Track {n}",
        "artist_name": "Someone",
        "duration": 180,
        "audiodownload_allowed": True,
        "audiodownload": f"https://example.com/{100 + n}.mp3",
    }
    for n in range(4)
]


def _urlopen_returning(payload: dict) -> MagicMock:
    mock = MagicMock()
    mock.__enter__ = lambda s: s
    mock.__exit__ = MagicMock(return_value=False)
    mock.read.return_value = json.dumps(payload).encode()
    return mock


@pytest.fixture
def jamendo(monkeypatch):
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    monkeypatch.setattr(
        "postroll.audio.urllib.request.urlopen",
        lambda *a, **k: _urlopen_returning({"results": TRACKS}),
    )
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)


# ── #453: failed downloads are counted and reported ──────────────────────────

def test_a_partial_candidate_set_says_how_many_did_not_download(jamendo, tmp_path, capsys):
    calls = {"n": 0}

    def flaky(url, dest):
        calls["n"] += 1
        if calls["n"] % 2 == 0:
            raise OSError("connection reset")
        dest.write_bytes(b"ID3")

    with patch("postroll.audio._download", side_effect=flaky):
        got = fetch_audio_candidates(tags="cinematic", count=4, cache_dir=tmp_path)

    assert 0 < len(got) < 4, f"expected a partial set, got {len(got)}"
    reported = capsys.readouterr().err
    assert "download" in reported.lower(), (
        f"a partial candidate set reported nothing: {reported!r}"
    )


def test_every_download_failing_is_not_reported_as_nothing_matching(jamendo, tmp_path):
    # An empty list here is indistinguishable from a search that matched
    # nothing, and only one of the two is retryable.
    with patch("postroll.audio._download", side_effect=OSError("connection reset")):
        with pytest.raises(JamendoUnavailable):
            fetch_audio_candidates(tags="cinematic", count=4, cache_dir=tmp_path)


def test_a_clean_run_says_nothing(jamendo, tmp_path, capsys):
    def ok(url, dest):
        dest.write_bytes(b"ID3")

    with patch("postroll.audio._download", side_effect=ok):
        got = fetch_audio_candidates(tags="cinematic", count=2, cache_dir=tmp_path)

    assert len(got) == 2
    assert "download" not in capsys.readouterr().err.lower(), (
        "a run where everything downloaded printed a warning, which is how a "
        "warning stops being read"
    )


def test_the_program_fetcher_reports_its_failed_downloads_too(monkeypatch, tmp_path):
    # Same defect, second copy: #453 names both fetchers.
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    monkeypatch.setattr(
        "postroll.audio.search_program_pieces",
        lambda *a, **k: [(t, 10.0, "A piece") for t in TRACKS],
    )

    with patch("postroll.audio._download", side_effect=OSError("connection reset")):
        with pytest.raises(JamendoUnavailable):
            fetch_program_audio_candidates(
                pieces=[{"title": "A piece"}], count=2, cache_dir=tmp_path
            )


def test_a_program_search_that_matched_nothing_is_still_an_empty_list(monkeypatch, tmp_path):
    # Nothing matched is a real answer and must not be turned into a failure.
    monkeypatch.setenv("JAMENDO_CLIENT_ID", "testkey")
    monkeypatch.setattr("postroll.audio.search_program_pieces", lambda *a, **k: [])

    assert fetch_program_audio_candidates(
        pieces=[{"title": "A piece"}], count=2, cache_dir=tmp_path
    ) == []


# ── #450: the reel says when it fell back to tag music ───────────────────────

def test_the_reel_reports_a_failed_program_match(monkeypatch):
    from postroll.media import generate_reel_scroll as mod

    def boom(pieces):
        raise JamendoUnavailable("the music service could not be reached.")

    monkeypatch.setattr("postroll.audio.fetch_audio_by_program", boom)
    monkeypatch.setattr("postroll.audio.fetch_audio", lambda tags: "/tmp/tag.mp3")

    seen: list[str] = []
    chosen = mod.resolve_reel_audio(
        audio_path=None, pieces=[{"title": "A piece"}], audio_tags="cinematic",
        on_warning=seen.append,
    )

    assert chosen == "/tmp/tag.mp3", "the reel must still get music"
    assert seen, "a failed program match was silent"
    assert "music service" in seen[0], seen


def test_a_programme_nothing_matched_is_not_reported_as_a_failure(monkeypatch):
    # The ordinary outcome for a programme of pieces Jamendo does not carry.
    from postroll.media import generate_reel_scroll as mod

    monkeypatch.setattr("postroll.audio.fetch_audio_by_program", lambda pieces: None)
    monkeypatch.setattr("postroll.audio.fetch_audio", lambda tags: "/tmp/tag.mp3")

    seen: list[str] = []
    chosen = mod.resolve_reel_audio(
        audio_path=None, pieces=[{"title": "A piece"}], audio_tags="cinematic",
        on_warning=seen.append,
    )

    assert chosen == "/tmp/tag.mp3"
    assert seen == [], f"an ordinary no-match was reported as a problem: {seen}"


def test_audio_handed_in_is_used_untouched(monkeypatch):
    from postroll.media import generate_reel_scroll as mod

    def never(*a, **k):
        raise AssertionError("Jamendo was asked for music that was already chosen")

    monkeypatch.setattr("postroll.audio.fetch_audio_by_program", never)
    monkeypatch.setattr("postroll.audio.fetch_audio", never)

    seen: list[str] = []
    assert mod.resolve_reel_audio(
        audio_path="/tmp/dans.mp3", pieces=[{"title": "A piece"}],
        audio_tags="cinematic", on_warning=seen.append,
    ) == "/tmp/dans.mp3"
    assert seen == []


def test_a_reel_with_no_programme_asks_only_for_tag_music(monkeypatch):
    from postroll.media import generate_reel_scroll as mod

    def never(pieces):
        raise AssertionError("searched the programme when there was none")

    monkeypatch.setattr("postroll.audio.fetch_audio_by_program", never)
    monkeypatch.setattr("postroll.audio.fetch_audio", lambda tags: "/tmp/tag.mp3")

    seen: list[str] = []
    assert mod.resolve_reel_audio(
        audio_path=None, pieces=[], audio_tags="cinematic", on_warning=seen.append,
    ) == "/tmp/tag.mp3"
    assert seen == []
