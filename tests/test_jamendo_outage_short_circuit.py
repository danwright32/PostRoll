"""L77: a per-piece search must not keep asking through an outage.

`_search_tracks_namesearch` is deliberately best effort: it runs once per
candidate query across every piece in a programme, so one unreachable query
degrades to no match rather than failing the whole render (#93).

That classification is right for ONE failure and wrong for a run of them. The
code waving each one through has no notion of volume, so a single blip and a
total outage arrive on exactly the same path and are indistinguishable, which
is L77. Reading the status envelope (#471) made it visible rather than fixing
it: an invalid client id now raises on every one of N queries, so a twelve
piece programme prints the same warning thirty times and then reports "no
piece matched", which is not what happened.

So the first failure that is the service refusing us, rather than one query
going wrong, stops the sweep: it is a fact about the account or the quota, it
will be true for every remaining query, and asking anyway spends more of the
quota the failure may be about.
"""

from __future__ import annotations

import json
from unittest.mock import MagicMock

from postroll.audio import search_program_pieces


PIECES = [
    {"composer": "Gustav Mahler", "title": "Symphony No. 2"},
    {"composer": "Johannes Brahms", "title": "Ein Deutsches Requiem"},
    {"composer": "Antonin Dvorak", "title": "Stabat Mater"},
    {"composer": "Edward Elgar", "title": "The Dream of Gerontius"},
]


def _responding(payload, calls):
    def fake(url, timeout=15):
        calls.append(url)
        mock = MagicMock()
        mock.__enter__ = lambda s: s
        mock.__exit__ = MagicMock(return_value=False)
        mock.read.return_value = json.dumps(payload).encode()
        return mock
    return fake


FAILED = {"headers": {"status": "failed", "code": 1,
                      "error_message": "invalid client id"}, "results": []}
EMPTY_OK = {"headers": {"status": "success", "code": 0, "error_message": ""},
            "results": []}


def test_a_refusal_stops_the_sweep_instead_of_repeating_it(monkeypatch, capsys):
    calls: list[str] = []
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(FAILED, calls))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    search_program_pieces(PIECES, "key")

    assert len(calls) == 1, (
        f"asked {len(calls)} times through an outage that was true on the first")


def test_the_outage_is_reported_once_and_named(monkeypatch, capsys):
    # Thirty copies of one warning is how a real report gets scrolled past.
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(FAILED, []))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    search_program_pieces(PIECES, "key")

    err = capsys.readouterr().err
    assert err.count("invalid client id") == 1
    assert "gave up" in err.lower() or "stopped" in err.lower()


def test_the_result_is_still_empty_so_the_render_carries_on(monkeypatch):
    # Best effort is still the contract: a reel with tag music beats no reel.
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(FAILED, []))
    monkeypatch.setattr("postroll.audio.time.sleep", lambda s: None)

    assert search_program_pieces(PIECES, "key") == []


def test_a_genuinely_empty_search_still_asks_every_piece(monkeypatch):
    # The service answered fine and nothing matched. That is a real answer per
    # query, so the sweep must not treat it as an outage and stop early.
    calls: list[str] = []
    monkeypatch.setattr("postroll.audio.urllib.request.urlopen",
                        _responding(EMPTY_OK, calls))

    search_program_pieces(PIECES, "key")

    assert len(calls) > 1, "a clean empty result is not a reason to give up"
