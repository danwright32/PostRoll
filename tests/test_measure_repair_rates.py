"""The rates the repair journal already holds and nothing computed (#1157, #1168).

#1157 is done when three real blog generations have been read back and the
per-check firing rate recorded. #1168 needs the share of attempts ending
`blocked` over a recent window, judged against a threshold, and says the
threshold has to be measured against the real distribution first (L172).

Both are the same arithmetic over the same journal, so it is one reading rather
than two, and neither is a threshold: this counts, it does not judge (L342).

`tools/read_repair_log.py` prints one narrative paragraph per record, which is
the right shape for "what did the app change in this post" and the wrong one
for a rate. Counting a rate off it by hand is the ad hoc reimplementation
beside the code that L107 is about.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.ai.repair_log import RepairLogUnreadable  # noqa: E402
from tools.measure_repair_rates import (  # noqa: E402
    EmptyJournal, Rates, read_rates, render)

NOW = datetime(2026, 9, 5, 12, 0, tzinfo=timezone.utc)


def attempt(outcome: str, *, codes=("alt_text_length",), days_ago: float = 0.0,
            marker: str = "a.jpg") -> dict:
    return {"kind": "attempt", "at": (NOW - timedelta(days=days_ago)).isoformat(),
            "event": "An Event", "event_id": "e1", "script": "generate_blog",
            "target": "alt", "marker": marker, "codes": list(codes),
            "before": "the words before", "after": "the words after",
            "outcome": outcome, "reason": ""}


def journal(tmp_path: Path, records: list[dict]) -> Path:
    path = tmp_path / "blog-repairs.jsonl"
    path.write_text("".join(json.dumps(r) + "\n" for r in records),
                    encoding="utf-8")
    return path


# ── what #1168 asks for ──────────────────────────────────────────────────────


def test_every_outcome_is_counted_against_the_attempts(tmp_path):
    rates = read_rates(journal(tmp_path, [
        attempt("repaired"), attempt("repaired"), attempt("tried"),
        attempt("blocked")]), now=NOW)

    assert rates.attempts == 4
    assert rates.by_outcome == {"repaired": 2, "tried": 1, "blocked": 1}


def test_the_blocked_share_is_over_attempts(tmp_path):
    """#1168's number. One unlucky call and the model being unreachable for an
    hour arrive identically unless something counts them against a volume."""
    rates = read_rates(journal(tmp_path, [
        attempt("blocked"), attempt("repaired"), attempt("repaired"),
        attempt("repaired")]), now=NOW)

    assert rates.share("blocked") == pytest.approx(0.25)


def test_an_outcome_nothing_recorded_is_absent_rather_than_zero(tmp_path):
    """A zero would be a claim that the pass met that state and came through it.
    Nothing recorded is a different fact and the report says which (L11)."""
    rates = read_rates(journal(tmp_path, [attempt("repaired")]), now=NOW)

    assert "blocked" not in rates.by_outcome
    assert rates.share("blocked") is None


def test_only_attempts_count_as_attempts(tmp_path):
    """The journal holds four kinds of record. A pass record says the pass ran;
    counting it as an attempt would inflate the denominator every rate here is
    divided by."""
    rates = read_rates(journal(tmp_path, [
        attempt("blocked"),
        {"kind": "pass", "at": NOW.isoformat(), "event": "An Event",
         "wording": "the repair pass ran", "selected": 3, "attempted": 3,
         "remaining_seconds": 40, "placed": []},
        {"kind": "moved", "at": NOW.isoformat(), "event": "An Event",
         "marker": "a.jpg", "rule": "orphan", "placed": True},
    ]), now=NOW)

    assert rates.attempts == 1


# ── what #1157 asks for ──────────────────────────────────────────────────────


def test_each_check_carries_its_own_firing_count(tmp_path):
    rates = read_rates(journal(tmp_path, [
        attempt("repaired", codes=("alt_text_length",)),
        attempt("blocked", codes=("alt_text_length", "invented_number")),
        attempt("tried", codes=("invented_number",)),
    ]), now=NOW)

    assert rates.by_code["alt_text_length"] == 2
    assert rates.by_code["invented_number"] == 2


def test_a_check_is_counted_once_per_attempt_it_fired_on(tmp_path):
    """An attempt carries every code that fired for that marker. Counting the
    codes list rather than the attempts would make one attempt against three
    findings read as three attempts."""
    rates = read_rates(journal(tmp_path, [
        attempt("repaired", codes=("a", "a", "b"))]), now=NOW)

    assert rates.by_code["a"] == 1
    assert rates.attempts == 1


def test_each_check_says_how_often_it_ended_repaired(tmp_path):
    """#1157 calibrates the damage gate, so what it needs per check is not only
    how often it fired but how often the repair survived."""
    rates = read_rates(journal(tmp_path, [
        attempt("repaired", codes=("a",)), attempt("blocked", codes=("a",)),
        attempt("repaired", codes=("b",))]), now=NOW)

    assert rates.repaired_by_code["a"] == 1
    assert rates.repaired_by_code["b"] == 1


# ── the window ───────────────────────────────────────────────────────────────


def test_a_window_keeps_only_what_falls_inside_it(tmp_path):
    """#1168 wants a RECENT share. The clock is passed in rather than read,
    so the fixture pins both ends of the relationship (L130)."""
    rates = read_rates(journal(tmp_path, [
        attempt("blocked", days_ago=0.5), attempt("repaired", days_ago=9.0)]),
        now=NOW, within_days=7)

    assert rates.attempts == 1
    assert rates.by_outcome == {"blocked": 1}


def test_a_record_with_no_timestamp_is_kept_and_counted_as_such(tmp_path):
    """Dropping it would quietly shrink the denominator, and a rate over a
    denominator nobody can see is the thing these issues are about."""
    stamped = attempt("repaired")
    del stamped["at"]

    rates = read_rates(journal(tmp_path, [stamped]), now=NOW, within_days=7)

    assert rates.attempts == 1
    assert rates.undated == 1


# ── the refusals ─────────────────────────────────────────────────────────────


def test_an_empty_journal_is_refused_rather_than_reported_as_clean(tmp_path):
    """Zero attempts and zero blocked reads exactly like a pass that met
    nothing wrong. It is not: it is a journal nothing has written to (L98)."""
    with pytest.raises(EmptyJournal):
        read_rates(journal(tmp_path, []), now=NOW)


def test_a_journal_that_cannot_be_read_is_not_an_empty_one(tmp_path):
    """The two must never share a type. One means no pass has run, the other
    means the evidence of every pass that did is unavailable."""
    path = tmp_path / "blog-repairs.jsonl"
    path.write_text("{not json\n", encoding="utf-8")

    with pytest.raises(RepairLogUnreadable):
        read_rates(path, now=NOW)


# ── what it prints ───────────────────────────────────────────────────────────


def test_it_prints_counts_and_never_the_words_it_repaired(tmp_path):
    """A privacy guard that scans the repository cannot see what a tool PRINTS,
    so a reading over the live journal otherwise puts a real post's prose into
    a transcript by a route nothing inspects (L222)."""
    rates = read_rates(journal(tmp_path, [attempt("repaired")]), now=NOW)

    printed = render(rates)

    assert "the words before" not in printed
    assert "the words after" not in printed
    assert "An Event" not in printed
    assert "1" in printed


def test_the_report_states_the_denominator_every_share_is_over(tmp_path):
    """A share whose denominator is not on the page is read against whichever
    one the reader assumes, and #1168 has two honest ones (L118)."""
    printed = render(read_rates(journal(tmp_path, [
        attempt("blocked"), attempt("repaired")]), now=NOW))

    assert "2 attempts" in printed


def test_a_journal_that_stops_being_readable_is_not_counted_as_absent(tmp_path):
    """The one honest zero is an ABSENT file, and nothing else.

    `_lines_in` runs only after `read_records` has already read the file, so
    this is the narrow case of it becoming unreadable in between. Answering 0
    would send the caller to EmptyJournal, which claims no pass has ever run,
    about a journal whose evidence is merely unavailable (L10, L11).
    """
    from tools.measure_repair_rates import _lines_in

    assert _lines_in(tmp_path / "never-written.jsonl") == 0

    with pytest.raises(RepairLogUnreadable):
        _lines_in(tmp_path)
