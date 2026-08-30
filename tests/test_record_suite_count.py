"""Writing down what the Swift suite holds, from a run that finished (#1017).

The floor in `tools/suite_counts.py` is only as good as the number it is derived
from, and that number has one job: to have been MEASURED. The issue asking for
the floor recorded 2,546 and the real figure was 2,599 by the time the work
started, which is the ordinary fate of a number typed into prose (L316).

So the record is written by a tool, from a transcript, and never by hand.

## Why a red run is refused

A suite that failed did not necessarily finish. Recording its count would pin
the floor to however far the run got, and because the floor only ever refuses
runs BELOW it, a low record is the one kind of wrong that nothing downstream
ever notices: every later run clears it (L182). `tools/record_test_durations.py`
refuses a red run for the same reason and says so at length.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from tools.record_suite_count import RecordError, count_from_transcript

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL = REPO_ROOT / "tools" / "record_suite_count.py"


def _transcript(executed: int, failures: int) -> str:
    return (
        f"Test Suite 'All tests' passed at 2026-08-29 22:00:00.000.\n"
        f"\t Executed {executed} tests, with {failures} failures (0 unexpected) "
        f"in 118.4 (119.0) seconds\n")


def test_a_green_run_is_recorded():
    assert count_from_transcript(_transcript(2599, 0)) == 2599


def test_a_red_run_is_refused_rather_than_recorded():
    """The refusal that keeps the floor honest, seen to fire (L1).

    A failing run may have stopped early. Recording it would lower the floor to
    wherever it stopped, and a floor that is too LOW is refused by nothing,
    forever.
    """
    with pytest.raises(RecordError) as refusal:
        count_from_transcript(_transcript(1400, 12))

    assert "12" in str(refusal.value), "the refusal must name the failures"


def test_a_transcript_with_no_total_is_refused():
    """Distinct from a red run: this one never reported at all (L11)."""
    with pytest.raises(RecordError, match="never reported"):
        count_from_transcript("** BUILD FAILED **\n")


def test_the_tool_writes_a_record_the_floor_can_read(tmp_path):
    """End to end, into a real file, read back by the reader that will use it.

    Asserting the tool "wrote something" would pass on a file the floor cannot
    parse. This reads it back through `recorded_swift_count`, which is the only
    consumer that matters (L3).
    """
    from tools.suite_counts import recorded_swift_count

    log = tmp_path / "swift.log"
    log.write_text(_transcript(2599, 0), encoding="utf-8")
    record = tmp_path / "swift_suite_count.json"

    result = subprocess.run(
        [sys.executable, str(TOOL), str(log), "--record", str(record)],
        capture_output=True, text=True, cwd=REPO_ROOT)

    assert result.returncode == 0, result.stdout + result.stderr
    assert recorded_swift_count(record) == 2599

    held = json.loads(record.read_text(encoding="utf-8"))
    assert held["measured_at_commit"], (
        "the record must carry the commit it was measured at, or it is a "
        "number with no way to re-measure it (L316)")


def test_the_tool_refuses_to_write_from_a_red_run(tmp_path):
    """The refusal reaches the FILE, not just the function.

    A tool that raises and then writes anyway is the defect this is about, and
    only touching the real path proves it does not.
    """
    log = tmp_path / "swift.log"
    log.write_text(_transcript(1400, 12), encoding="utf-8")
    record = tmp_path / "swift_suite_count.json"

    result = subprocess.run(
        [sys.executable, str(TOOL), str(log), "--record", str(record)],
        capture_output=True, text=True, cwd=REPO_ROOT)

    assert result.returncode != 0, result.stdout
    assert not record.exists(), (
        "a red run wrote the record anyway, so the floor is now pinned to a "
        "run that did not finish")


def test_the_recorded_commit_can_be_the_one_the_run_actually_happened_at(tmp_path):
    """A CI transcript was measured at ITS commit, not at whatever is checked out.

    The provenance field exists so the number can be re-measured. Stamping the
    local HEAD onto a transcript downloaded from a runner makes that field a
    confident lie, and it is the one field a reader will not go and check
    (L249, L176). Recording from a foreign log therefore states its commit.
    """
    log = tmp_path / "swift.log"
    log.write_text(_transcript(2599, 0), encoding="utf-8")
    record = tmp_path / "swift_suite_count.json"
    elsewhere = "0123456789abcdef0123456789abcdef01234567"

    result = subprocess.run(
        [sys.executable, str(TOOL), str(log), "--record", str(record),
         "--commit", elsewhere],
        capture_output=True, text=True, cwd=REPO_ROOT)

    assert result.returncode == 0, result.stdout + result.stderr
    held = json.loads(record.read_text(encoding="utf-8"))
    assert held["measured_at_commit"] == elsewhere
