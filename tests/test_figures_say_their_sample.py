"""A recorded duration that never said how many runs it came from (#1328).

Driven against written fixtures rather than only against this repository's own,
because a guard whose single case is the tree it guards passes on the day that
tree happens to be clean and has never been seen to fail (L1).
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools import check_figures_say_their_sample as guard  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent


def _fixture(root: Path, name: str, body: dict) -> Path:
    target = root / name
    target.write_text(json.dumps(body))
    return target


def test_a_bare_duration_is_reported(tmp_path):
    _fixture(tmp_path, "swift_suite_cost.json", {"wall_seconds": 212.2})

    found = guard.unsourced(root=tmp_path)

    assert [(f.file, f.figures) for f in found] == [
        ("swift_suite_cost.json", ("wall_seconds",))]


def test_a_duration_beside_runs_is_accepted(tmp_path):
    _fixture(tmp_path, "swift_suite_cost.json", {"wall_seconds": 212.2, "runs": 1})

    assert guard.unsourced(root=tmp_path) == []


def test_runs_on_an_enclosing_block_covers_what_is_inside_it(tmp_path):
    """`changed_job_timing.json` states `runs: 69` once, above its whole list."""
    _fixture(tmp_path, "changed_job_timing.json",
             {"runs": 69, "inner": {"seconds": [33, 35, 37]}})

    assert guard.unsourced(root=tmp_path) == []


def test_a_list_of_durations_is_a_figure_rather_than_its_own_sample(tmp_path):
    """Four shard_seconds are four shards of ONE run, not four readings."""
    _fixture(tmp_path, "guard_sweep_timing.json",
             {"shard_seconds": [1783, 1772, 1590, 1600]})

    found = guard.unsourced(root=tmp_path)

    assert [f.figures for f in found] == [("shard_seconds",)]


def test_a_list_of_readings_confers_no_sample_on_its_members(tmp_path):
    """The two entries of `readings` are two MACHINES, not two readings of one.

    This is the rule that was tried the other way round first and was wrong in
    both fixtures it would have covered.
    """
    _fixture(tmp_path, "swift_suite_cost.json",
             {"readings": [{"wall_seconds": 212.2}, {"wall_seconds": 123.4}]})

    found = guard.unsourced(root=tmp_path)

    assert len(found) == 2, found
    assert {f.where for f in found} == {"readings[0]", "readings[1]"}


def test_a_mapping_of_durations_is_a_figure_too(tmp_path):
    """`test_file_durations.json` records one per file under a single key."""
    _fixture(tmp_path, "test_file_durations.json",
             {"seconds": {"test_a.py": 0.9, "test_b.py": 24.0}})

    assert [f.figures for f in guard.unsourced(root=tmp_path)] == [("seconds",)]


def test_a_mapping_of_durations_beside_passes_is_accepted(tmp_path):
    _fixture(tmp_path, "test_file_durations.json",
             {"passes": 3, "seconds": {"test_a.py": 0.9}})

    assert guard.unsourced(root=tmp_path) == []


def test_a_deadline_is_not_a_reading(tmp_path):
    """Asking how many runs produced a limit somebody chose has no answer."""
    _fixture(tmp_path, "guard_sweep_timing.json",
             {"deadline_seconds": 1800, "runs": 1, "shard_seconds": [1783]})

    assert guard.unsourced(root=tmp_path) == []


def test_a_deadline_alone_is_not_reported_even_with_no_sample(tmp_path):
    _fixture(tmp_path, "guard_sweep_timing.json", {"deadline_seconds": 1800})

    assert guard.unsourced(root=tmp_path) == []


def test_a_boolean_is_not_a_duration(tmp_path):
    """`True` is `1` to isinstance, and would otherwise read as one second."""
    _fixture(tmp_path, "alt_text_call_timing.json", {"seconds": True})

    assert guard.unsourced(root=tmp_path) == []


def test_a_file_it_cannot_parse_is_refused_rather_than_skipped(tmp_path):
    """A skipped file reads exactly like a clean one (L98)."""
    (tmp_path / "swift_suite_cost.json").write_text("{not json")

    with pytest.raises(guard.CannotRead) as refusal:
        guard.unsourced(root=tmp_path)

    assert "swift_suite_cost.json" in str(refusal.value)


def test_the_scan_actually_reads_the_files_it_claims_to(tmp_path):
    """A control: the files it reads must move with what is on disk."""
    _fixture(tmp_path, "swift_suite_cost.json", {"runs": 1})
    before = guard.scanned_files(root=tmp_path)

    _fixture(tmp_path, "guard_sweep_timing.json", {"runs": 1})
    after = guard.scanned_files(root=tmp_path)

    assert [p.name for p in before] == ["swift_suite_cost.json"]
    assert len(after) == 2


def test_every_named_fixture_is_actually_there():
    """A name that no longer exists is silently exempt from its own guard (L96)."""
    missing = [name for name in guard.MEASUREMENT_FIXTURES
               if not (REPO_ROOT / "tests" / "fixtures" / name).is_file()]

    assert missing == [], (
        f"{missing} are listed as measurement fixtures but are not there, so "
        "each is exempt from this check while still reading as covered")


def test_this_repository_records_no_figure_without_its_sample():
    """The guard itself."""
    found = guard.unsourced()

    assert found == [], "\n".join(
        f"{f.file} at {f.where}: {', '.join(f.figures)} say no sample size"
        for f in found)


def test_it_exits_nonzero_when_it_finds_one(tmp_path):
    _fixture(tmp_path, "swift_suite_cost.json", {"wall_seconds": 212.2})

    done = subprocess.run(
        [sys.executable, str(REPO_ROOT / "tools" / "check_figures_say_their_sample.py"),
         "--root", str(tmp_path)], capture_output=True, text=True)

    assert done.returncode == 1
    assert "wall_seconds" in done.stdout
    assert "runs: 1 is a fine answer" in done.stdout.replace("`", "")
