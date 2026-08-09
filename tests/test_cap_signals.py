"""Recognise a usage cap, and admit when we cannot (#211).

Dan's decision is that hitting a cap STOPS the run and asks him, rather than
spending anything further. #206 built the halt. This is the half that decides
when to pull it.

The issue is explicit that the signal must be OBSERVED, not taken from
documentation. It has not been observed yet: triggering a real subscription cap
on demand is not something this session can do. That constraint shapes the
design rather than being worked around.

So classification is deliberately conservative in one direction and loud in the
other. A failure that matches a known cap signal halts the week. A failure that
matches nothing is NOT quietly treated as ordinary: it is recorded verbatim, so
the first real cap this app meets leaves behind the exact text needed to
calibrate the patterns, instead of being swallowed and lost.

The reverse mistake is the expensive one. Classifying an ordinary blip as a cap
would stop a week that had nothing wrong with it, and a wrongly halted run
costs Dan an evening. So a match has to be specific.
"""

from __future__ import annotations

import json

import pytest

from postroll.ai import cap_signals as cs


# ── what we can recognise ─────────────────────────────────────────────────────

@pytest.mark.parametrize("text", [
    "Claude usage limit reached. Your limit will reset at 3pm.",
    "You've reached your usage limit for Claude Code.",
    "5-hour limit reached ∙ resets 8pm",
])
def test_a_known_cap_message_is_recognised(text):
    assert cs.classify(text).kind == "cap"


@pytest.mark.parametrize("text", [
    "Error: connection reset by peer",
    "API Error: 500 Internal Server Error",
    "overloaded_error",
])
def test_an_ordinary_failure_is_not_a_cap(text):
    """Halting a week that had nothing wrong with it costs Dan an evening, so
    a cap match has to be specific."""
    assert cs.classify(text).kind != "cap"


def test_a_transient_failure_is_named_as_transient():
    assert cs.classify("API Error: 529 overloaded_error").kind == "transient"


def test_an_unrecognised_failure_is_unknown_rather_than_ordinary():
    assert cs.classify("something nobody has seen before").kind == "unknown"


def test_the_reason_quotes_the_text_so_a_halt_can_be_explained():
    result = cs.classify("Claude usage limit reached. Resets at 3pm.")

    assert "usage limit" in result.detail.lower()


def test_a_cap_result_carries_the_reset_time_when_the_message_has_one():
    """Dan's choice is wait or pay, and he cannot make it without knowing how
    long the wait is."""
    result = cs.classify("Claude usage limit reached. Your limit will reset at 3pm.")

    assert result.resets_at and "3pm" in result.resets_at


def test_a_cap_message_with_no_reset_time_does_not_invent_one():
    result = cs.classify("You've reached your usage limit for Claude Code.")

    assert result.resets_at is None


# ── the part we have not observed ─────────────────────────────────────────────

def test_an_unknown_failure_is_recorded_verbatim_for_calibration(tmp_path):
    """The patterns above are uncalibrated: no real cap has been seen. The
    first one that happens must leave its exact text behind, or it is spent and
    lost and the next attempt guesses again."""
    log = tmp_path / "unrecognised.jsonl"

    cs.classify("a brand new failure shape", record_to=log)

    assert log.exists()
    assert "a brand new failure shape" in json.loads(log.read_text().strip())["text"]


def test_a_recognised_failure_is_not_recorded_as_needing_calibration(tmp_path):
    log = tmp_path / "unrecognised.jsonl"

    cs.classify("Claude usage limit reached.", record_to=log)

    assert not log.exists()


def test_recording_never_raises_even_when_it_cannot_write(tmp_path):
    """Classification runs on a failure path. It must not add a second one."""
    bad = tmp_path / "nope" / "deep" / "u.jsonl"
    bad.parent.mkdir(parents=True)
    bad.parent.chmod(0o500)
    try:
        assert cs.classify("new shape", record_to=bad).kind == "unknown"
    finally:
        bad.parent.chmod(0o700)


def test_the_patterns_declare_that_they_are_uncalibrated():
    """A guard shipped before it has ever seen the real thing must say so, or
    the next reader takes it for measured fact."""
    assert cs.CALIBRATED is False


# ── an unknown failure must not silently halt or silently continue ────────────

def test_only_a_cap_halts_the_week():
    from postroll.ai.generate_week import FatalGenerationError

    assert cs.should_halt(cs.classify("Claude usage limit reached.")) is True
    assert cs.should_halt(cs.classify("API Error: 529 overloaded_error")) is False
    assert cs.should_halt(cs.classify("something new")) is False
    assert FatalGenerationError is not None


def test_an_unknown_failure_says_it_was_not_understood(capsys):
    cs.classify("something new", announce=True)

    err = capsys.readouterr().err.lower()
    assert "not recognise" in err or "not recognised" in err


# ── wired to the halt #206 built ──────────────────────────────────────────────

def test_a_cap_during_a_day_stops_the_whole_week(tmp_path, monkeypatch):
    """Detection is useless unwired. Without this the classifier can be
    correct, tested, and never once consulted by a real run."""
    import postroll.ai.generate_week as gw
    from postroll.ai.generate_week import FatalGenerationError

    photo = tmp_path / "p.jpg"
    photo.write_bytes(b"\xff\xd8\xff\xdb" + b"0" * 64)
    tried = []

    def run(*, day, **kwargs):
        tried.append(day)
        raise RuntimeError("Claude usage limit reached. Your limit will reset at 3pm.")

    monkeypatch.setattr(gw, "generate_caption", run)
    manifest = {
        "event": "E", "org": "O", "venue": "V", "date": "2026-08-08",
        "program": {"performers": [], "pieces": []},
        "days": {d: {"photos": [str(photo)]} for d in
                 ("sunday", "monday", "tuesday")},
        "blog_photos": [],
    }

    with pytest.raises(FatalGenerationError):
        gw.generate_week(manifest, tmp_path / "out.json")

    assert tried == ["sunday"], \
        f"the run kept spending after hitting the cap: tried {tried}"


def test_an_ordinary_error_during_a_day_still_lets_the_week_finish(tmp_path, monkeypatch):
    """The other direction, and the more expensive mistake: a blip must not be
    read as a cap and cancel an evening."""
    import postroll.ai.generate_week as gw

    photo = tmp_path / "p.jpg"
    photo.write_bytes(b"\xff\xd8\xff\xdb" + b"0" * 64)
    tried = []

    def run(*, day, **kwargs):
        tried.append(day)
        raise RuntimeError("API Error: 529 overloaded_error")

    monkeypatch.setattr(gw, "generate_caption", run)
    manifest = {
        "event": "E", "org": "O", "venue": "V", "date": "2026-08-08",
        "program": {"performers": [], "pieces": []},
        "days": {d: {"photos": [str(photo)]} for d in
                 ("sunday", "monday", "tuesday")},
        "blog_photos": [],
    }
    gw.generate_week(manifest, tmp_path / "out.json")

    assert "tuesday" in tried, "one transient blip abandoned the whole week"


def test_the_stopped_reason_tells_dan_when_it_resets(tmp_path, monkeypatch):
    """His choice is wait or pay, and he cannot make it without the wait."""
    import postroll.ai.generate_week as gw
    from postroll.ai.generate_week import FatalGenerationError

    photo = tmp_path / "p.jpg"
    photo.write_bytes(b"\xff\xd8\xff\xdb" + b"0" * 64)

    def run(*, day, **kwargs):
        raise RuntimeError("Claude usage limit reached. Your limit will reset at 3pm.")

    monkeypatch.setattr(gw, "generate_caption", run)
    out = tmp_path / "out.json"
    with pytest.raises(FatalGenerationError):
        gw.generate_week({
            "event": "E", "org": "O", "venue": "V", "date": "2026-08-08",
            "program": {"performers": [], "pieces": []},
            "days": {"sunday": {"photos": [str(photo)]}}, "blog_photos": [],
        }, out)

    saved = json.loads(out.read_text())
    assert "3pm" in (saved.get("stopped_reason") or ""), \
        "the run stopped without telling him how long the wait is"


# ── #217: the recorded failures must be readable, and must be said out loud ──
#
# `_record` appended unclassifiable failures so the first real subscription cap
# would leave its exact wording behind for calibration, and then nothing read
# the file, surfaced it, or prompted anyone to look. A cap cannot be triggered
# on demand, so there is one cheap chance to capture the real text, and a
# write-only file is exactly how that chance gets missed.


def test_nothing_recorded_reads_as_nothing(tmp_path):
    assert cs.unrecognised(tmp_path / "absent.jsonl") == []
    assert cs.report_unrecognised(tmp_path / "absent.jsonl") is None


def test_a_recorded_failure_can_be_read_back(tmp_path):
    path = tmp_path / "unrecognised.jsonl"
    cs.classify("something nobody has seen before", record_to=path)

    assert cs.unrecognised(path) == ["something nobody has seen before"]


def test_several_failures_are_all_read_back(tmp_path):
    path = tmp_path / "unrecognised.jsonl"
    cs.classify("first odd thing", record_to=path)
    cs.classify("second odd thing", record_to=path)

    assert cs.unrecognised(path) == ["first odd thing", "second odd thing"]


def test_a_half_written_line_is_still_reported(tmp_path):
    """A truncated record is still evidence something happened, so it must not
    be silently dropped by the reader."""
    path = tmp_path / "unrecognised.jsonl"
    path.write_text('{"text": "good one"}\n{"text": "cut off mid\n', encoding="utf-8")

    entries = cs.unrecognised(path)
    assert len(entries) == 2
    assert "good one" in entries


def test_the_report_names_the_file_and_quotes_the_text(tmp_path):
    path = tmp_path / "unrecognised.jsonl"
    cs.classify("Claude usage cap hit, resets at 3pm", record_to=path)

    report = cs.report_unrecognised(path)
    assert str(path) in report
    assert "resets at 3pm" in report


def test_the_report_says_the_patterns_are_still_uncalibrated(tmp_path):
    """While CALIBRATED is False this text is the only thing that can make it
    True, so the report has to say what to do with it."""
    assert cs.CALIBRATED is False, "update this test when calibrating"
    path = tmp_path / "unrecognised.jsonl"
    cs.classify("odd", record_to=path)

    report = cs.report_unrecognised(path)
    assert "uncalibrated" in report
    assert "CALIBRATED" in report


def test_the_report_does_not_dump_hundreds_of_entries(tmp_path):
    path = tmp_path / "unrecognised.jsonl"
    for i in range(20):
        cs.classify(f"odd thing {i}", record_to=path)

    report = cs.report_unrecognised(path)
    assert "20 failure(s)" in report
    assert "and 15 more" in report


def test_an_unreadable_file_does_not_raise_on_the_way_out(tmp_path):
    """This is read at the end of a run that may already have gone wrong; it
    must not add a second failure."""
    d = tmp_path / "a-directory-not-a-file.jsonl"
    d.mkdir()
    assert cs.unrecognised(d) == []
    assert cs.report_unrecognised(d) is None


# ── the wiring, not just the reader (#217) ───────────────────────────────────


def test_the_week_result_carries_the_unrecognised_failures(tmp_path, monkeypatch):
    """Built is not wired: a reader nothing calls leaves the file as invisible
    as it was before."""
    from postroll.ai import generate_week as gw

    monkeypatch.setattr(gw.cap_signals, "unrecognised",
                        lambda *a, **k: ["Claude usage cap hit, resets at 3pm"])
    out = tmp_path / "week.json"
    gw._write_results(out, {"sunday": {"caption": "s"}}, complete=True)

    payload = json.loads(out.read_text())
    assert payload["unrecognised_failures"] == ["Claude usage cap hit, resets at 3pm"]


def test_a_clean_run_carries_an_empty_list_rather_than_omitting_the_key(tmp_path, monkeypatch):
    # A missing key and "nothing recorded" must not be the same shape, or the
    # app cannot tell "checked, nothing there" from "never checked".
    from postroll.ai import generate_week as gw

    monkeypatch.setattr(gw.cap_signals, "unrecognised", lambda *a, **k: [])
    out = tmp_path / "week.json"
    gw._write_results(out, {}, complete=True)

    payload = json.loads(out.read_text())
    assert payload["unrecognised_failures"] == []


def test_a_partial_run_carries_them_too(tmp_path, monkeypatch):
    """A run stopped by a cap is exactly when the recorded text matters most,
    so the stopped path must not be the one that drops it."""
    from postroll.ai import generate_week as gw

    monkeypatch.setattr(gw.cap_signals, "unrecognised", lambda *a, **k: ["odd"])
    out = tmp_path / "week.json"
    gw._write_results(out, {}, complete=False, stopped_reason="usage limit reached")

    payload = json.loads(out.read_text())
    assert payload["complete"] is False
    assert payload["unrecognised_failures"] == ["odd"]


def test_the_run_reports_the_file_on_stderr_at_the_end():
    """The report has to be reached from the run, not merely exist."""
    import inspect
    from postroll.ai import generate_week as gw

    source = inspect.getsource(gw)
    assert "report_unrecognised()" in source, (
        "nothing in generate_week calls the report, so the file stays as "
        "invisible as it was"
    )
