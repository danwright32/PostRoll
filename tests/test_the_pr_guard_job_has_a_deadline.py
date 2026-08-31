"""The per-pull-request guard job stops itself, and says who that blocks (#1086).

The `full` sweep passes `--deadline-seconds 1800` so a shard that runs out of
time reports WHICH entries went unproven, rather than being killed by
`timeout-minutes` and reporting CANCELLED, which is what a superseded run
reports too (L11). The `changed` job passed no deadline at all: a wide diff
either finished or was killed 45 minutes later with nothing saying what it
reached.

Measured over 2026-08-30 and 31, this job was the sole thing holding FIVE
separate merges, for 15 to 19 minutes each, with every other check already
green, and #1072 waited 1,140s on it alone.

The number is chosen from the distribution of the job's own past runs, and those
readings live in `tests/fixtures/changed_job_timing.json` so the choice can be
re-measured rather than believed (L316). Re-measure with
`venv/bin/python tools/measure_changed_job.py`.
"""

from __future__ import annotations

import json
import re
import statistics
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "guards.yml"
RECORD = REPO_ROOT / "tests" / "fixtures" / "changed_job_timing.json"


def measured() -> dict:
    assert RECORD.exists(), (
        f"{RECORD.relative_to(REPO_ROOT)} is missing, so nothing says where the "
        "deadline below came from and every check here is against a number "
        "nobody measured")
    found = json.loads(RECORD.read_text(encoding="utf-8"))
    assert found.get("seconds"), (
        "the record holds no readings, so the checks below compare the deadline "
        "against an empty distribution and pass whatever it is (L98)")
    return found


def workflow() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def declared_deadline() -> int:
    """What the `changed` job actually passes, read out of the workflow.

    Read rather than assumed, because a deadline in a record and no deadline in
    the workflow is exactly the state this issue found: built is not wired (L3).
    """
    found = re.search(r"check_guards\.py --changed --deadline-seconds (\d+)",
                      workflow())
    assert found, (
        "the `changed` job no longer passes --deadline-seconds, so a wide diff "
        "is back to being killed by timeout-minutes with nothing saying what it "
        "reached, and a killed job reports CANCELLED, which is what a superseded "
        "run reports too (L11)")
    return int(found.group(1))


def job_timeout_seconds() -> int:
    """The `changed` job's own cap, in seconds."""
    block = workflow().split("  changed:", 1)[1].split("\n  full:", 1)[0]
    found = re.search(r"timeout-minutes: (\d+)", block)
    assert found, "the `changed` job carries no timeout-minutes at all (L313)"
    return int(found.group(1)) * 60


def percentile(seconds: list[int], share: float) -> int:
    ordered = sorted(seconds)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))]


# ── the deadline is wired, and it is the record's number ─────────────────────

def test_the_changed_job_passes_a_deadline():
    assert declared_deadline() > 0


def test_the_workflow_and_the_record_name_the_same_deadline():
    """Two copies of one number, held equal rather than trusted (L41).

    The record is where the choice is explained; the workflow is what actually
    happens. If they drift, the explanation describes a deadline nothing uses.
    """
    assert declared_deadline() == measured()["deadline_seconds"], (
        f"guards.yml passes {declared_deadline()}s and "
        f"{RECORD.name} says {measured()['deadline_seconds']}s was chosen")


# ── it is the deadline that fires, not the runner's cap ──────────────────────

def test_the_deadline_is_well_under_the_job_s_own_cap():
    """Whichever fires first decides what is reported, and only the deadline can
    say which entries went unproven."""
    deadline, cap = declared_deadline(), job_timeout_seconds()
    assert deadline < cap, (
        f"the deadline is {deadline}s and the job is capped at {cap}s, so the "
        "cap fires first and reports CANCELLED")
    assert cap - deadline >= 300, (
        f"only {cap - deadline}s separates the deadline from the cap, which is "
        "less than this job's setup takes (Xcode, xcodegen, pip, ffmpeg: about "
        "five minutes), so a slow setup puts the cap first")


# ── it is sized from the distribution, not picked round (L172) ───────────────

def test_the_deadline_does_not_fire_on_an_ordinary_run():
    """A check that fires on ordinary runs is one that gets turned off (L36)."""
    seconds = measured()["seconds"]
    p75 = percentile(seconds, 0.75)
    assert declared_deadline() > p75, (
        f"the deadline is {declared_deadline()}s and three runs in four finish "
        f"within {p75}s, so this would fire on ordinary pull requests")


def test_the_deadline_can_actually_fire():
    """A limit nothing has ever crossed is a limit nobody has measured (L182).

    The runs above it are the 15 to 36 minute ones this issue is about.
    """
    seconds = measured()["seconds"]
    over = [s for s in seconds if s >= declared_deadline()]
    assert over, (
        f"no recorded run of this job reached {declared_deadline()}s, so the "
        "deadline has never been in reach and protects nothing")
    assert len(over) / len(seconds) < 0.2, (
        f"{len(over)} of {len(seconds)} recorded runs are at or over the "
        "deadline, which is not a tail any more: either the job has got much "
        "slower or the deadline is too tight")


def test_the_deadline_is_not_inside_the_dense_middle():
    """A threshold sitting where the readings are crowded turns the count it
    produces into noise: a small uniform shift carries many runs across it at
    once and reads as a sudden regression (L172).

    So it must sit in a real gap. The nearest recorded run on either side has to
    be further away than the median run is long.
    """
    deadline = declared_deadline()
    seconds = sorted(measured()["seconds"])
    below = max((s for s in seconds if s < deadline), default=0)
    above = min((s for s in seconds if s >= deadline), default=deadline * 10)
    gap = above - below
    assert gap >= statistics.median(seconds), (
        f"the deadline at {deadline}s sits between recorded runs of {below}s and "
        f"{above}s, a gap of {gap}s, which is narrower than the median run "
        f"({statistics.median(seconds):.0f}s). Pick a number in a real gap.")
