"""#1179: no test may write into Dan's real blog repair journal.

`RepairLog` defaults its path to `default_log_path()`, which is the live file at
`~/Library/Application Support/PostRoll/blog-repairs.jsonl`. `generate_blog`,
`swap_blog_photos` and `retry_blog_repair` all construct one with no path, so
every test driving those paths appended to it.

Measured before the fix, 2026-09-01: 2,775 records in the live journal, all
written that day, and NONE belonging to any of the 21 real stored events. The
event names were `E`, the empty string, `The Green Room 42` and
`Greenwich House Theater`, which are test fixtures.

It leaked silently because the write is append-only and best effort: nothing
fails when a record lands in the wrong file, so the only way to see it was to
read the artefact.

Two things this ruins beyond tidiness. #1162 puts the record on the blog panel,
which would have opened on 2,775 fabricated rows. #1157 calibrates the damage
gate from what the app's own repairs did, and its input was entirely fixture
data, so it would have produced numbers that looked measured and meant nothing
(L2, L48, L196).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai.repair_log import RepairLog, default_log_path, read_records
from postroll.data_root import data_root, running_under_test


def test_the_suite_knows_it_is_a_test_run():
    """Everything below rests on this, so it is asserted rather than assumed.
    If pytest stopped setting the variable, every guard here would pass by
    being unable to tell a test from the app (L98)."""
    assert running_under_test()


def test_the_default_journal_path_is_not_the_live_one_under_test():
    """The refusal lives in the resource, because the three scripts CONSTRUCT
    their own log rather than receiving one, and a construction site inside the
    code under test is beyond any seam the caller could offer (L196)."""
    live = data_root() / "blog-repairs.jsonl"
    assert default_log_path() != live, (
        "a test run resolves the journal to the live file, so anything driving "
        "generate_blog, swap_blog_photos or retry_blog_repair appends to Dan's "
        "real record")


def test_a_log_built_the_way_the_scripts_build_it_writes_somewhere_harmless():
    """Measured by where the write LANDS, not by what the path says (L322)."""
    log = RepairLog(event="E", script="generate_blog")
    assert log.attempt(target="a.jpg", marker="a.jpg", codes=["alt_text_length"],
                       before="was", after="now", outcome="repaired", reason="")

    assert log.path.exists()
    assert log.path != data_root() / "blog-repairs.jsonl"
    written = [json.loads(line) for line in log.path.read_text().splitlines()]
    assert written[-1]["marker"] == "a.jpg"


def test_the_live_journal_is_never_the_target_of_a_write_under_test(tmp_path):
    """The control: a path handed in explicitly is still honoured, so the
    redirect above has not simply broken the seam it was protecting."""
    log = RepairLog(tmp_path / "mine.jsonl", event="E", script="s")
    log.attempt(target="a.jpg", marker="a.jpg", codes=[], before=None,
                after=None, outcome="blocked", reason="")

    assert (tmp_path / "mine.jsonl").exists()
    assert read_records(tmp_path / "mine.jsonl")


def test_the_redirect_is_per_run_rather_than_one_shared_file():
    """Two logs in one run may share a file; what matters is that the file is
    not the live one. Asserted so a future change to a fixed temp path is a
    deliberate choice rather than a surprise."""
    first = RepairLog(event="A", script="generate_blog").path
    second = RepairLog(event="B", script="swap_blog_photos").path
    live = data_root() / "blog-repairs.jsonl"

    assert first != live and second != live


def test_a_chosen_data_directory_is_still_honoured(tmp_path, monkeypatch):
    """The redirect must be no wider than its reason (L324).

    A test that sets POSTROLL_DATA_DIR has already pointed the app somewhere of
    its own, and that IS the seam this is protecting. The first version
    redirected unconditionally and broke
    `test_blog_repair_log.py::test_the_log_honours_the_apps_own_data_directory`,
    which asserts exactly that behaviour.
    """
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))

    assert default_log_path().parent == tmp_path


# --- the same guard on the usage log (#1180) -------------------------------
#
# Swept rather than fixed one at a time: the defect is the class, not the
# instance (L30, L195). The journal is where it bit; the usage log is the same
# shape, dormant only because tests stub the model runner and so never reach
# the line that records. Its two neighbours, the audio cache and the failure
# signals, already guard.

from postroll.ai import usage_log


def test_the_usage_log_path_still_tells_the_truth_about_where_it_lives():
    """The guard is on the WRITE, not on the resolver, and that matters.

    Redirecting `default_log_path` was tried first and moved a file nobody was
    looking at: `cap_signals.default_record_path` derives its own file from this
    one's PARENT, so `unrecognised-failures.jsonl` moved into the temp directory
    too, and the test asserting the live path is right went red. A resolver that
    stops telling the truth breaks every derivation from it (L204).
    """
    live = Path.home() / "Library" / "Application Support" / "PostRoll" / "usage.jsonl"
    assert usage_log.default_log_path() == live

    from postroll.ai import cap_signals
    assert cap_signals.default_record_path().parent == live.parent, (
        "the derived failure-signals file moved with it")


def test_a_usage_record_written_under_test_lands_somewhere_harmless():
    """Measured by where the write LANDS, not by what the path says (L322)."""
    live = Path.home() / "Library" / "Application Support" / "PostRoll" / "usage.jsonl"
    before = live.read_text() if live.exists() else None

    usage_log.record(usage_log.Usage(model="claude-sonnet-5", input_tokens=1,
                                     output_tokens=1),
                     step="a-test-that-should-not-reach-the-live-log")

    after = live.read_text() if live.exists() else None
    assert after == before, "the usage log write reached the live file"


def test_a_chosen_data_directory_is_still_honoured_by_the_usage_log(
        tmp_path, monkeypatch):
    """The redirect stays no wider than its reason (L324)."""
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))
    assert usage_log.default_log_path().parent == tmp_path
