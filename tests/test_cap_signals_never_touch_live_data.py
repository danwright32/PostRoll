"""The cap detector must not write into Dan's real data while tests run.

`classify()` records an unrecognised failure so the first real subscription cap
leaves its exact wording behind for calibration (#217). With no path given it
falls back to `default_record_path()`, which resolves to the app's live data
directory, and three tests in test_cap_signals.py called it that way.

That was invisible while nothing read the file. It stopped being invisible the
moment #262 wired a reader: 269 lines of "something new" and "ordinary failure"
had accumulated in the live file, and the next real generation would have told
Dan it hit 269 failures the app did not recognise, every one of them a test
fixture.

A test suite must be structurally unable to reach live data (L2). "Remember to
pass a temp path" is not structural, so the refusal lives inside the module
itself, where no future test can forget it.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai import cap_signals as cs


def test_recording_refuses_the_live_default_path_while_testing(monkeypatch, tmp_path):
    live = tmp_path / "Application Support" / "PostRoll" / "unrecognised-failures.jsonl"
    monkeypatch.setattr(cs, "default_record_path", lambda: live)

    cs.classify("a shape nothing has seen")

    assert not live.exists(), (
        "the test suite wrote into the app's live data directory. Every local "
        "run adds more, and the app now READS this file, so the junk reaches a "
        "screen Dan sees."
    )


def test_it_says_so_rather_than_failing_silently(monkeypatch, tmp_path, capsys):
    # A refusal nobody can see is indistinguishable from a write that worked,
    # which is how somebody "fixes" a test by removing the temp path and never
    # learns they broke the isolation.
    monkeypatch.setattr(cs, "default_record_path",
                        lambda: tmp_path / "live" / "unrecognised-failures.jsonl")
    cs.classify("a shape nothing has seen")
    assert "refus" in capsys.readouterr().err.lower()


def test_an_explicit_path_still_records_normally(tmp_path):
    # The refusal is about the DEFAULT path only. A test that names its own file
    # is doing the right thing and must keep working, or the feature becomes
    # untestable and the next person deletes the guard.
    log = tmp_path / "failures.jsonl"
    cs.classify("a shape nothing has seen", record_to=log)

    lines = log.read_text(encoding="utf-8").strip().splitlines()
    assert [json.loads(l)["text"] for l in lines] == ["a shape nothing has seen"]


def test_classification_itself_is_unaffected_by_the_refusal(monkeypatch, tmp_path):
    # Refusing to WRITE must not change what the detector decides. A guard that
    # quietly alters the answer is worse than the leak it prevents.
    monkeypatch.setattr(cs, "default_record_path",
                        lambda: tmp_path / "live" / "f.jsonl")
    assert cs.classify("something nobody has seen before").kind == "unknown"
    assert cs.classify("Claude usage limit reached.").kind == "cap"
    assert cs.classify("API Error: 529 overloaded_error").kind == "transient"


def test_outside_a_test_run_the_default_path_is_still_written(monkeypatch, tmp_path):
    # The whole point of the field. If the refusal fired in production the app
    # would never capture a real cap's wording, and #258 could never start.
    live = tmp_path / "live" / "unrecognised-failures.jsonl"
    monkeypatch.setattr(cs, "default_record_path", lambda: live)
    monkeypatch.setattr(cs, "_running_under_test", lambda: False)

    cs.classify("the real thing, whatever it turns out to say")

    assert live.exists(), "a real run must still record the wording #258 needs"
    assert "the real thing" in live.read_text(encoding="utf-8")


def test_the_live_default_path_points_where_the_app_actually_looks(monkeypatch):
    # Guards the seam itself: if default_record_path stopped resolving to the
    # data root, the refusal above would be protecting nothing.
    monkeypatch.delenv("POSTROLL_DATA_DIR", raising=False)
    path = cs.default_record_path()
    assert path.name == "unrecognised-failures.jsonl"
    assert "PostRoll" in str(path)


def test_the_data_dir_override_is_honoured(monkeypatch, tmp_path):
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))
    assert cs.default_record_path() == tmp_path / "unrecognised-failures.jsonl"


@pytest.mark.parametrize("text", ["something new",
                                  "something nobody has seen before",
                                  "ordinary failure"])
def test_the_strings_that_polluted_the_live_file_no_longer_reach_it(text, monkeypatch, tmp_path):
    # Named literally, because these three are what was found in the live file
    # and they are still used by the suite next door.
    live = tmp_path / "live" / "unrecognised-failures.jsonl"
    monkeypatch.setattr(cs, "default_record_path", lambda: live)
    cs.classify(text)
    assert not live.exists()
