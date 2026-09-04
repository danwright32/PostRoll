"""The sweep starts a Mac per DUE shard, not one per shard (#1344).

#1259 put a Linux gate in front of the seven macOS shards, and that gate works
out exactly which of them have something to prove. It wrote that list to an
output and nothing read it: the matrix was still the literal `[1..7]`, so any
one shard being due started all seven and six of them spent a billed macOS
minute discovering they had nothing to do. Stored data with a writer and no
reader (L46).

The case that produces it is real rather than theoretical. A shard that hits
its own 1,800 second deadline leaves its share unproved while the other six
passed, which happened on 2026-09-01, 2026-08-24, 2026-08-27, 2026-08-29 and
2026-08-30. The next run then has exactly one shard with work.

## The empty matrix, which is why the list is never empty

GitHub treats a matrix vector with no values as a workflow ERROR, not as a
skipped job. The job's `if:` already short circuits when nothing is due, but
the order in which GitHub evaluates a job condition against its matrix is not
something this repo should be betting the sweep on: getting it wrong makes the
whole workflow fail on exactly the quiet day it was built to make free.

So the gate NEVER emits an empty list. When nothing is due it emits every
shard, which the `if:` then skips, and the failure direction is the sweep
running when it could have skipped rather than the workflow refusing to parse.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

from tools.check_guard_sweep_due import SHARD_COUNT, decide_sweep
from tools.guard_sweep_history import Sweep

from source_text import without_prose

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "guards.yml"

NOW = datetime(2026, 9, 4, 12, 0, tzinfo=timezone.utc)
TREE = "a" * 40


def swept(passed: set[int], *, days_ago: float = 1.0) -> list[Sweep]:
    return [Sweep(run_id=100, head_sha=TREE, created_at=NOW - timedelta(days=days_ago),
                  event="schedule", ran_shards=frozenset(range(1, SHARD_COUNT + 1)),
                  passed_shards=frozenset(passed))]


def ask(history) -> list[int]:
    return list(decide_sweep(sha=TREE, shards=SHARD_COUNT, history=history,
                             now=NOW).for_the_matrix())


# ── what the matrix is handed ────────────────────────────────────────────────


def test_one_unproved_shard_starts_one_mac():
    """The whole saving. Six shards that would each burn a billed macOS minute
    to discover they have nothing to do are simply not started."""
    everything_but_six = set(range(1, SHARD_COUNT + 1)) - {6}

    assert ask(swept(everything_but_six)) == [6]


def test_every_unproved_shard_is_started():
    """The other direction, and the one that must never be wrong: a shard with
    work that is left out of the matrix is not swept at all, and nothing says
    so (L98)."""
    assert ask(swept({1, 2})) == [3, 4, 5, 6, 7][:SHARD_COUNT - 2]


def test_a_tree_nobody_has_proved_starts_all_of_them():
    assert ask(swept(set(), days_ago=1.0)) == list(range(1, SHARD_COUNT + 1))


def test_nothing_due_still_names_every_shard_rather_than_none():
    """The empty matrix trap. GitHub treats a matrix vector with no values as a
    workflow ERROR rather than a skipped job, so an empty list here would fail
    the whole workflow on precisely the quiet day the gate exists to make free.

    The job's own condition is what skips it. This list is never consulted then,
    and naming every shard means the worst case if that condition is ever wrong
    is a sweep that ran when it need not have, rather than a workflow that
    cannot be parsed.
    """
    proved = decide_sweep(sha=TREE, shards=SHARD_COUNT,
                          history=swept(set(range(1, SHARD_COUNT + 1))), now=NOW)

    assert proved.run is False, "this fixture is meant to be a quiet day"
    assert list(proved.for_the_matrix()) == list(range(1, SHARD_COUNT + 1)), (
        "the gate hands the matrix an empty list on a quiet day, which GitHub "
        "refuses to parse rather than skipping")


def test_the_matrix_is_never_empty_whatever_was_asked():
    """The rule above, stated over every shape the answer can take."""
    for passed in (set(), {1}, {1, 2, 3}, set(range(1, SHARD_COUNT + 1))):
        assert ask(swept(passed)), (
            f"an empty matrix for a run where shards {sorted(passed)} had "
            f"passed, which GitHub fails the workflow on")


# ── the count lives in one place ─────────────────────────────────────────────


def test_the_workflow_takes_its_width_from_the_shard_count():
    """The matrix used to be a literal `[1, 2, 3, 4, 5, 6, 7]` and the command
    was told `/7` beside it, so the two could disagree and every shard would
    still report success (L41). Both come from SHARD_COUNT now, through the
    gate, so there is one number rather than two that have to be kept in step.
    """
    # Through without_prose: the comments in guards.yml name every
    # construct below, and a guard reading raw text is answered by the
    # prose about a rule as readily as by the rule (L103, L135).
    text = without_prose(WORKFLOW)

    assert not re.search(r"^\s*shard: \[[0-9, ]+\]\s*$", text, re.M), (
        "the matrix is a hardcoded list again, so it can disagree with what "
        "check_guards is told about how many ways the sweep is split")
    assert "fromJson(needs.due.outputs.shards)" in text, (
        "the matrix is not built from the gate's answer, so the shards it "
        "starts are not the shards that have work")
    assert not re.search(r"--shard \$\{\{ matrix\.shard \}\}/\d", text), (
        "the denominator handed to check_guards is a literal beside the "
        "matrix, which is the pair that could drift")


def test_the_shard_count_is_a_number_the_deadline_projection_can_read():
    """`tests/test_guard_sweep_fits_its_deadline.py` projects the largest shard
    against the 1,800 second deadline and needs the width to do it. It read the
    matrix literal; with the matrix dynamic there is nothing there to read, so
    the count has to be somewhere it can still be found."""
    assert isinstance(SHARD_COUNT, int) and SHARD_COUNT >= 1


# ── the width the shards are told about is the width that was asked ──────────


def test_the_count_it_reports_is_the_width_it_was_asked_about(tmp_path):
    """The half of the agreement no workflow text can show.

    The matrix and the `--shard N/M` denominator both come from this one
    output. If it ever reported a different number than the sweep was asked
    about, the shards would divide the registry one way and prove it another:
    entries proved twice, entries proved by nobody, and every shard green
    (L41, L98).
    """
    import subprocess
    import os
    import sys

    output = tmp_path / "github_output"
    done = subprocess.run(
        # This interpreter, not whatever `python` resolves to on the PATH: the
        # runner has one and this Mac does not, and a test that cannot find it
        # would report the tool as broken (L177).
        [sys.executable, "tools/check_guard_sweep_due.py", "--shards", "3",
         "--sha", TREE, "--output", str(output)],
        cwd=REPO_ROOT, capture_output=True, text=True,
        env=dict(os.environ, GH_TOKEN="", GITHUB_RUN_ID=""))

    assert done.returncode == 0, done.stderr
    written = dict(
        line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)

    assert written["count"] == "3", (
        f"asked about 3 shards and reported a width of {written['count']!r}, "
        f"so the matrix and the denominator would divide the registry "
        f"differently")
    assert len(json.loads(written["shards"])) <= 3, (
        f"the matrix would be handed {written['shards']}, which names shards "
        f"the sweep was not asked to split into")
