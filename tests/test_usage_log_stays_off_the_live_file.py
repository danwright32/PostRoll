"""#1180: the usage log must not write into Dan's live file from a test.

Its own file since #1183. These three arrived with #1179 and #1180 as one sweep
of the same defect and were parked in `test_blog_repair_log.py`, which is about
the repair JOURNAL, because a file of their own would have been unmeasured:
`tests/fixtures/test_file_durations.json` decides which files
`make test-python-fast` skips, so adding a file forces a re-measurement, and
every reading available on 2026-09-01 was taken on a machine running Lightroom
at between 430% and 517% of the CPU. Two recordings of the identical suite two
hours apart differed by 17% and moved a file onto the floor (L224, L356).

So the choice was between a bad measurement and a slightly wrong home, and the
wrong home was the cheaper one to reverse. This is the reversal.

The guard is on the WRITE rather than on the resolver, and that distinction is
the substance of the file: redirecting `default_log_path` was tried first and
moved a file nobody was looking at.
"""

from __future__ import annotations

from pathlib import Path

from postroll.ai import usage_log

# Swept rather than fixed one at a time: the defect is the class, not the
# instance (L30, L195). The journal is where it bit; the usage log is the same
# shape, dormant only because tests stub the model runner and so never reach
# the line that records. Its two neighbours, the audio cache and the failure
# signals, already guard.



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
