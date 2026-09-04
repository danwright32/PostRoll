"""#1189: the tool that turns a chosen estimate into a measured one.

It times real Claude calls against a real event with real photographs, so
nothing here runs one. What IS tested is everything around that: the refusal, the
passes it knows, and what it does when the pass it is pointed at cannot be
started. Those are the parts that decide whether money is spent and whether the
reading that comes back means anything (L2).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from measure_blog_calls import PASSES, RECORD, main, record  # noqa: E402


def test_it_refuses_until_somebody_has_decided_to_spend(capsys):
    """A refusal rather than a prompt. A prompt handed to somebody in a hurry is
    a yes, and this spends real Claude calls on real photographs (L9)."""
    code = main(["--pass", "blog", "--event", "abc"])

    assert code == 2, "it ran the pass without anybody saying to"
    said = capsys.readouterr().err
    assert "--i-mean-it" in said, "it does not say how to proceed deliberately"
    assert "paid" in said or "spend" in said, (
        "the refusal does not say that running it costs money, which is the "
        "whole reason it refuses")


def test_the_refusal_names_what_it_would_run_and_against_what(capsys):
    """A refusal that does not say what it was about to do leaves the reader to
    work out whether they meant it (L11)."""
    main(["--pass", "photos", "--event", "an-event-id"])

    said = capsys.readouterr().err
    assert PASSES["photos"] in said
    assert "an-event-id" in said


def test_an_unknown_pass_is_refused_by_the_parser():
    """Named passes rather than a module path, so it cannot be pointed at
    something that costs a different amount than the person expected."""
    with pytest.raises(SystemExit):
        main(["--pass", "something-else", "--event", "abc", "--i-mean-it"])


def test_every_named_pass_names_a_module_that_exists():
    """A pass naming a module nothing can import is an option that can only
    fail, and it fails AFTER the person has said they mean to spend (L109)."""
    import importlib.util

    missing = [name for name, module in PASSES.items()
               if importlib.util.find_spec(module) is None]

    assert not missing, (
        f"these passes name a module that is not there: {missing}. Somebody "
        f"choosing one would be refused only after committing to spend")


def test_a_pass_whose_module_cannot_be_started_says_so_before_spending(monkeypatch):
    """The module is there and has no `run`. Nothing has been paid for at that
    point, and the message says so, because a failure here that read like a
    failed API call would send somebody looking at the wrong thing (L11)."""
    import measure_blog_calls as tool

    monkeypatch.setitem(tool.PASSES, "blog", "json")  # a module with no `run`

    with pytest.raises(SystemExit) as refusal:
        tool.main(["--pass", "blog", "--event", "abc", "--i-mean-it"])

    said = str(refusal.value)
    assert "nothing was spent" in said.lower(), (
        "it does not say that no money went, so the reader cannot tell this "
        "from a call that failed")


def test_a_reading_is_appended_rather_than_replacing_what_was_there(tmp_path,
                                                                    monkeypatch):
    """One reading is a sample of one, and an estimate derived from a single
    call is the same guess with a date on it, which reads as MORE trustworthy
    rather than less (L316). So they accumulate."""
    import measure_blog_calls as tool

    store = tmp_path / "blog_call_timing.json"
    monkeypatch.setattr(tool, "RECORD", store)

    tool.record("blog", 121.4, "first")
    tool.record("blog", 143.9, "second")

    held = json.loads(store.read_text(encoding="utf-8"))
    assert [r["seconds"] for r in held["readings"]] == [121.4, 143.9]
    assert [r["note"] for r in held["readings"]] == ["first", "second"]


def test_a_reading_says_when_it_was_taken_and_which_pass_it_was(tmp_path,
                                                               monkeypatch):
    """A duration with no date and no subject cannot be compared against
    anything later (L316)."""
    import measure_blog_calls as tool

    store = tmp_path / "blog_call_timing.json"
    monkeypatch.setattr(tool, "RECORD", store)
    tool.record("photos", 88.2, "")

    reading = json.loads(store.read_text(encoding="utf-8"))["readings"][0]
    assert reading["pass"] == "photos"
    assert reading["measured_on"].count("-") == 2


def test_the_record_lives_where_the_estimates_would_read_it():
    """The fixture path is part of the contract: RunEstimate's provenance will
    name it when a reading exists, so a tool writing somewhere else would leave
    the estimate chosen forever with a file nobody reads beside it (L46)."""
    assert RECORD.parent == REPO_ROOT / "tests" / "fixtures"
    assert RECORD.name.endswith(".json")
