"""The line the guard jobs print and the pattern that reads it, held together (#1090).

`tools/check_job_durations.py` divides each job's duration by how much work it
did, which is what makes the series a rate rather than a total (#1039). The two
guard families were the ones left NOT_NORMALISED: their logs reported `N guards
checked`, and dividing by a count of items whose costs differ by 90x hands a
bare comparison the confidence of a measured one.

They print recorded entry-milliseconds now. A line and the regex reading it are
two halves of one contract, and the regex is the half that fails SILENTLY:
`work_done` returns None on a miss, which the caller is built to treat as "could
not measure" rather than as an error, so a wording change would quietly take
these two families back to NOT_NORMALISED with nothing saying so (#1085).

So this asserts the pattern against a line the producer actually made, never
against a line written here to match it: a fixture shaped so the rule fires
proves nothing about the rule (L48).
"""

from __future__ import annotations

import json
import re

import pytest

from tools.check_guards import Entry, Outcome, Result, guard_work_line
from tools.check_job_durations import WORK_PATTERNS, work_done


def entry(name: str, *, swift: bool) -> Entry:
    return Entry(name=name, file="f.swift" if swift else "f.py", find="a",
                 replace="b",
                 test=(f"PostRollTests/Suite/{name}" if swift
                       else f"tests/test_x.py::{name}"),
                 breaks="something")


def result(name: str, *, swift: bool, seconds: float = 1.0) -> Result:
    return Result(entry(name, swift=swift), Outcome.KILLED, "", seconds)


@pytest.fixture
def record(tmp_path, monkeypatch):
    """A cost record the line is computed from, rather than the live one."""
    path = tmp_path / "guard_entry_costs.json"
    seconds = {"s1": 29.0, "s2": 31.0, "p1": 0.8, "p2": 1.2}
    path.write_text(json.dumps({
        "seconds": seconds,
        "measured": {name: {"run": "r", "scale": 1.0} for name in seconds},
    }))
    monkeypatch.setattr("tools.guard_entry_costs.RECORD", path)
    return path


def test_the_pattern_reads_the_line_the_tool_prints(record):
    """The whole point: one producer, one reader, one fixture (L52, L58)."""
    line = guard_work_line([result("s1", swift=True), result("p1", swift=False)])
    for family in ("changed", "full"):
        pattern = WORK_PATTERNS[family][0]
        found = re.findall(pattern, line)
        assert found, (
            f"the {family} pattern does not match the line check_guards prints: "
            f"{line!r}. A miss returns None, which reads as 'could not measure' "
            "and takes this family silently back to NOT_NORMALISED"
        )
        assert int(found[-1]) == 29800


def test_work_done_reads_a_whole_log_not_just_the_line(record):
    """Through the real reader, over a log with other lines around it."""
    line = guard_work_line([result("s1", swift=True), result("s2", swift=True)])
    log = "\n".join([
        "[1 of 2, 0s] s1: KILLED in 28.9s, pytest reported failing tests",
        "2 guards checked, 2 killed their mutation, 0 did not",
        line,
        "wrote 2 entry timing(s) to /tmp/t.json",
    ])
    assert work_done(log, "changed") == 60000
    assert work_done(log, "full (3)") == 60000


def test_a_sub_second_run_still_reports_work(record):
    """Rounded to SECONDS a `changed` run proving one Python entry reports zero,
    and a zero divisor is refused as unmeasurable rather than read as a very
    fast job (L11)."""
    line = guard_work_line([result("p1", swift=False)])
    assert work_done(line, "changed") == 800


def test_an_unreadable_record_says_so_rather_than_reporting_no_work(
        tmp_path, monkeypatch):
    """A missing record and a job that did nothing are different things.

    Printing zero would make the second read like the first, and the rate would
    then be computed from a divisor nobody measured (L10, L11).
    """
    monkeypatch.setattr("tools.guard_entry_costs.RECORD", tmp_path / "gone.json")
    line = guard_work_line([result("s1", swift=True)])
    assert "unmeasured" in line
    assert work_done(line, "full (1)") is None


def test_a_run_that_proved_nothing_says_that_rather_than_zero(record):
    line = guard_work_line([])
    assert "no entries were proved" in line
    assert work_done(line, "changed") is None


def test_the_line_says_how_many_of_its_entries_were_measured(record):
    """An estimate and a reading divide identically, so a rate computed from a
    record covering three entries out of five hundred has to be readable as
    such (L11)."""
    line = guard_work_line([result("s1", swift=True), result("brand-new", swift=True)])
    assert "2 entries, 1 of them measured" in line
