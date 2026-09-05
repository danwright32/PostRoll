"""Whether two recorded fixtures say the same MEASUREMENT (#1392).

Every recorder stamps which run produced a reading and when. Those fields move
on every run whether the number did or not, so a check that asks "is there
anything new to propose" by comparing the whole file answers yes every time.
The proposal is then recommitted, its head moves, and the checks it had just
earned belong to a commit that is no longer there.

L40 is the same comparison failing the other way, and reading it as "compare
the whole file" is what produces this, so what has to be compared is the
measurement rather than the bytes around it.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.same_measurement import (  # noqa: E402
    PROVENANCE_ONLY, Unreadable, measurement_of, same_measurement)

TOOL = REPO_ROOT / "tools" / "same_measurement.py"


def write(path: Path, payload: dict) -> Path:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def run(a: Path, b: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(TOOL), str(a), str(b)],
                          capture_output=True, text=True)


# ── what counts as the measurement ───────────────────────────────────────────


def test_the_run_and_the_day_are_not_part_of_the_measurement():
    reading = {"count": 3175, "measured_on": "2026-09-05",
               "measured_at_commit": "aaaaaaa", "measured_from_run": "111",
               "measured_from": "3175 tests, read from run 111"}

    assert measurement_of(reading) == {"count": 3175}


def test_the_instruction_for_re_measuring_is_kept():
    """`re_measure_with` names the command, not the run. It is part of what the
    record SAYS, and a change to it is a real change worth proposing."""
    assert "re_measure_with" not in PROVENANCE_ONLY
    assert measurement_of({"count": 1, "re_measure_with": "a tool"}) == {
        "count": 1, "re_measure_with": "a tool"}


def test_the_per_entry_run_map_is_provenance():
    """`guard_entry_costs.json` records which run and what scale each of its 660
    entries came from, under `measured`. Those move on a re-record while the
    seconds they describe do not."""
    record = {"seconds": {"a": 1.0}, "runs": 1,
              "measured": {"a": {"run": "111", "scale": 1.0}}}

    assert measurement_of(record) == {"seconds": {"a": 1.0}, "runs": 1}


def test_the_sample_size_is_part_of_the_measurement():
    """`runs` says what the figure was measured over, which is the thing #1328
    added it for. A record that changed it changed what it claims."""
    assert measurement_of({"seconds": {"a": 1.0}, "runs": 3})["runs"] == 3


def test_provenance_nested_inside_a_list_is_stripped_too():
    """Nothing writes this today. It is stripped anyway, because the rule is
    about what the FIELD means and not about where a record happens to put it."""
    record = {"cold": [{"seconds": 9.0, "measured_on": "2026-09-05"}]}

    assert measurement_of(record) == {"cold": [{"seconds": 9.0}]}


# ── the comparison ───────────────────────────────────────────────────────────


def test_two_readings_of_the_same_number_are_the_same_measurement(tmp_path):
    a = write(tmp_path / "a.json", {"count": 3175, "measured_from_run": "111",
                                    "measured_on": "2026-09-05"})
    b = write(tmp_path / "b.json", {"count": 3175, "measured_from_run": "222",
                                    "measured_on": "2026-09-06"})

    assert same_measurement(a, b) is True


def test_a_different_number_is_a_different_measurement(tmp_path):
    a = write(tmp_path / "a.json", {"count": 3175, "measured_from_run": "111"})
    b = write(tmp_path / "b.json", {"count": 3201, "measured_from_run": "111"})

    assert same_measurement(a, b) is False


def test_a_measurement_the_other_does_not_have_is_a_difference(tmp_path):
    """A record that GAINED a figure is a new measurement, and comparing only
    the keys both hold would call it unchanged."""
    a = write(tmp_path / "a.json", {"seconds": {"one": 1.0}})
    b = write(tmp_path / "b.json", {"seconds": {"one": 1.0, "two": 2.0}})

    assert same_measurement(a, b) is False


# ── the failure paths ────────────────────────────────────────────────────────


def test_an_unreadable_record_is_refused_rather_than_called_the_same(tmp_path):
    """The dangerous direction. Answering "same" on a file that could not be
    read would silently stop a real measurement being proposed, and the caller
    could not tell that from a run with nothing new (L11, L98)."""
    a = write(tmp_path / "a.json", {"count": 1})
    b = tmp_path / "b.json"
    b.write_text("{not json", encoding="utf-8")

    with pytest.raises(Unreadable):
        same_measurement(a, b)


def test_a_missing_record_is_refused_by_name(tmp_path):
    a = write(tmp_path / "a.json", {"count": 1})

    with pytest.raises(Unreadable) as refusal:
        same_measurement(a, tmp_path / "gone.json")

    assert "gone.json" in str(refusal.value)


# ── the exit codes, which are what the shell script reads ────────────────────


def test_the_same_measurement_exits_zero(tmp_path):
    a = write(tmp_path / "a.json", {"count": 3175, "measured_from_run": "111"})
    b = write(tmp_path / "b.json", {"count": 3175, "measured_from_run": "222"})

    assert run(a, b).returncode == 0


def test_a_different_measurement_exits_one(tmp_path):
    a = write(tmp_path / "a.json", {"count": 3175})
    b = write(tmp_path / "b.json", {"count": 3201})

    assert run(a, b).returncode == 1


def test_an_unreadable_record_exits_two_and_says_why(tmp_path):
    """Two rather than one, because the shell reads "different" as "commit and
    push". An unreadable record must not take that branch by accident, and it
    must not take the quiet one either."""
    a = write(tmp_path / "a.json", {"count": 1})
    b = tmp_path / "b.json"
    b.write_text("{not json", encoding="utf-8")

    refused = run(a, b)

    assert refused.returncode == 2
    assert "b.json" in refused.stderr
