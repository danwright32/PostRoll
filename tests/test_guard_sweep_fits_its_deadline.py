"""#989: the sweep is sized against its deadline, not left to find it.

The full guard sweep proves every registry entry, split across shards, each
under a deadline `check_guards` enforces itself so that a shard which runs out
of time can say WHICH entries went unproven rather than being killed by
`timeout-minutes` and reporting CANCELLED, which is what a superseded run
reports too (L11).

That deadline was being approached silently. Measured from the first scheduled
sweep after #989 moved the cadence, run 33329633579 on 2026-08-30 at commit
21ea9a18, over 469 entries and four shards:

    full (1)  1783s     99% of the 1800s deadline
    full (2)  1772s     98%
    full (3)  1590s     88%
    full (4)  1600s     89%

Two things follow, and only the second is what #989 expected.

The shards are already BALANCED: 1,783s against a mean of 1,686s is an imbalance
of 1.06, so dealing entries by measured time instead of by cost class, which is
what the issue asks for, is worth about a hundred seconds. That is not the
problem.

The problem is the TOTAL, and it grows with the registry. 6,745s over 469
entries is 14.4s each, every entry added is another 14.4s spread over the shards,
and 26 entries have been added since that reading. The sweep does not get slower;
it gets bigger, and nothing was watching the difference (L323).

So this projects the largest shard for the registry AS IT IS NOW and holds it to
a fraction of the deadline, rather than waiting for a red sweep to report it
(L172, L315). When it goes red the answer is another shard, not a wider band.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TIMING = REPO_ROOT / "tests" / "fixtures" / "guard_sweep_timing.json"
REGISTRY = REPO_ROOT / "tests" / "fixtures" / "guard_mutations"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "guards.yml"

#: How much of its deadline the largest projected shard may use.
#:
#: Not a round number chosen for comfort. The reading it has to tolerate is the
#: measured imbalance between shards, 1.06, plus the growth that happens between
#: one look at this and the next. At 14.4s an entry and six shards, 0.80 goes
#: red at about 600 entries, which is 105 more than today and roughly four
#: months at the rate the registry has grown, while the real wall at 1800s is
#: 751 entries. So it fires with a season of warning rather than on the day the
#: sweep breaks.
DEADLINE_SHARE = 0.80


def measured() -> dict:
    if not TIMING.exists():
        raise AssertionError(
            f"{TIMING.relative_to(REPO_ROOT)} is missing, so nothing here can "
            "say what the sweep costs and every projection below is of an "
            "empty set")
    return json.loads(TIMING.read_text(encoding="utf-8"))


def entries_now() -> int:
    found = sorted(REGISTRY.glob("*.json"))
    assert found, (
        f"no registry entries under {REGISTRY.relative_to(REPO_ROOT)}, so the "
        "projection below is about a sweep with nothing in it")
    return len(found)


def shards_now() -> int:
    """How many shards the workflow actually runs, read from the matrix."""
    text = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(r"^\s*shard: \[([0-9, ]+)\]\s*$", text, re.M)
    assert match, (
        "guards.yml declares no `shard: [...]` matrix any more, so this cannot "
        "say how many ways the sweep is split")
    return len([piece for piece in match.group(1).split(",") if piece.strip()])


def seconds_per_entry() -> float:
    reading = measured()
    total = sum(reading["shard_seconds"])
    assert reading["entries"] > 0 and total > 0, (
        "the recorded sweep covered no entries or took no time, so a cost per "
        "entry cannot be derived from it")
    return total / reading["entries"]


def imbalance() -> float:
    """How much larger the biggest shard was than the average one."""
    seconds = measured()["shard_seconds"]
    return max(seconds) / (sum(seconds) / len(seconds))


def projected_largest_shard() -> float:
    return seconds_per_entry() * entries_now() / shards_now() * imbalance()


# ── the measurement is real ──────────────────────────────────────────────────

def test_the_recorded_reading_covers_every_shard_it_claims():
    reading = measured()
    assert len(reading["shard_seconds"]) == reading["shards"], (
        "the recorded sweep names a different number of shards from the number "
        "of readings it holds, so the cost per entry derived from it is over a "
        "sweep that never happened")
    assert all(second > 0 for second in reading["shard_seconds"])


def test_the_shards_really_were_close_to_balanced():
    """The reason #989's dealing half is worth little, held to the measurement.

    If a future reading shows real imbalance this goes red and dealing entries
    by measured time becomes the answer after all, rather than being dismissed
    on a number nobody re-checked (L316).
    """
    assert imbalance() < 1.25, (
        f"the largest shard was {imbalance():.2f}x the mean, so the shards are "
        "no longer balanced by count alone and dealing them by measured time "
        "is worth doing (#989)")


# ── the sweep fits ───────────────────────────────────────────────────────────

def test_the_largest_shard_is_projected_well_inside_its_deadline():
    projected = projected_largest_shard()
    deadline = measured()["deadline_seconds"]

    assert projected < DEADLINE_SHARE * deadline, (
        f"the sweep's largest shard projects to {projected:.0f}s against a "
        f"{deadline}s deadline, which is {projected / deadline:.0%} of it and "
        f"past the {DEADLINE_SHARE:.0%} this holds. At {seconds_per_entry():.1f}s "
        f"an entry, {entries_now()} entries and {shards_now()} shards, a shard "
        "that runs out of time reports its remaining entries as UNPROVEN, so "
        "the guards stop being re-proved while the workflow still goes green "
        "(L98). Add a shard rather than widening this: the shards are balanced "
        f"to {imbalance():.2f}x, so the total is what grew, not the split.")


def test_the_projection_would_notice_the_registry_growing():
    """A guard driven to a comfortable number stops being read as a measurement
    (L182), so this shows what it would say about a bigger registry."""
    per_entry, shards, spread = seconds_per_entry(), shards_now(), imbalance()
    deadline = measured()["deadline_seconds"]

    at_double = per_entry * entries_now() * 2 / shards * spread

    assert at_double > DEADLINE_SHARE * deadline, (
        "twice the registry still projects inside the limit, so this check "
        "cannot fail for the reason it exists and is not measuring growth")


# ── the two places the shard count is written agree ──────────────────────────

def test_the_matrix_and_the_command_split_the_sweep_the_same_way():
    """The count is in the matrix and again in `--shard N/M`. They are two
    copies of one number and a guard proves them equal rather than trusting
    them (L41): split six ways while told it is four, two shards would prove
    the same entries twice and a third of the registry would go unproven with
    every shard green."""
    text = WORKFLOW.read_text(encoding="utf-8")
    told = re.search(r"--shard \$\{\{ matrix\.shard \}\}/(\d+)", text)

    assert told, "guards.yml no longer passes --shard N/M, so nothing splits"
    assert int(told.group(1)) == shards_now(), (
        f"the matrix runs {shards_now()} shards and check_guards is told there "
        f"are {told.group(1)}. Entries would be proved twice or not at all, and "
        "every shard would still report success")
