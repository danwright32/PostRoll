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

from tools import guard_entry_costs

from tools.check_guard_sweep_due import SHARD_COUNT

from source_text import without_prose

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
    """How many shards the workflow actually runs.

    Read from SHARD_COUNT rather than from a matrix literal. #1344 made the
    matrix the shards that actually have work, expanded from the gate's answer,
    so there is no list in the workflow to count any more and the width lives
    in one place instead (L41).
    """
    assert isinstance(SHARD_COUNT, int) and SHARD_COUNT >= 1, (
        f"SHARD_COUNT is {SHARD_COUNT!r}, so this cannot say how many ways the "
        f"sweep is split and the projection below is about nothing")
    return SHARD_COUNT


def seconds_per_entry() -> float:
    reading = measured()
    total = sum(reading["shard_seconds"])
    assert reading["entries"] > 0 and total > 0, (
        "the recorded sweep covered no entries or took no time, so a cost per "
        "entry cannot be derived from it")
    return total / reading["entries"]


def registry_kinds() -> dict[str, bool]:
    """Every entry the registry holds now, and whether it pays an app build."""
    kinds: dict[str, bool] = {}
    for path in sorted(REGISTRY.glob("*.json")):
        entry = json.loads(path.read_text(encoding="utf-8"))
        kinds[entry["name"]] = entry["test"].startswith("PostRollTests/")
    assert kinds, (
        f"no registry entries under {REGISTRY.relative_to(REPO_ROOT)}, so the "
        "projection below is about a sweep with nothing in it")
    return kinds


def imbalance() -> float:
    """How much larger the biggest shard is than the average one.

    Computed from the DEAL the sweep will actually make, over the registry as
    it is now, priced from tests/fixtures/guard_entry_costs.json (#1090).

    It used to be read off the four shard totals of one recorded sweep. That
    number could only ever describe the deal that had already happened, under
    the class-wise round robin that #1090 replaced, and there was no way to
    re-measure it without paying for a whole sweep on the runner. This one is
    re-derived on every run of the suite, so a change to the dealing or to the
    registry moves it immediately.
    """
    costs = guard_entry_costs.costs_for(registry_kinds())
    shards = guard_entry_costs.deal(list(costs.seconds), shards_now(),
                                    costs.seconds)
    return guard_entry_costs.imbalance(shards, costs.seconds)


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


def test_the_deal_the_sweep_will_make_is_balanced():
    """Measured over the deal itself, not over one recorded sweep's totals.

    The old version read the imbalance off four shard totals from a sweep that
    had already run, so it could not notice the dealing getting worse and could
    not be re-measured without paying for another sweep. This deals the registry
    as it stands and measures the result, in the same seconds the deal is made
    in, so a check on the balance cannot pass while measuring something else
    (L63).
    """
    spread = imbalance()
    assert spread < 1.10, (
        f"the largest shard is dealt {spread:.2f}x the mean. Dealing by measured "
        "cost should get well inside this; a spread this wide means either the "
        "cost record has gone stale (most entries estimated rather than "
        "measured) or one entry is now larger than a whole shard's fair share")


def test_most_of_the_deal_is_measured_rather_than_estimated():
    """An estimate and a reading deal identically.

    So a record covering three entries out of five hundred produces a confident
    looking partition of almost entirely guessed numbers, and every projection
    below inherits that (L11, L98). This is what says the record still describes
    the registry, and its remedy is one command.
    """
    costs = guard_entry_costs.costs_for(registry_kinds())
    total = len(costs.seconds)
    share = costs.measured / total
    assert share > 0.85, (
        f"only {costs.measured} of {total} registry entries carry a measured "
        f"cost ({share:.0%}); the rest are estimated from the median of their "
        "kind, so the deal below is mostly guesswork. Re-record from the newest "
        "sweep: tools/record_guard_costs.py --from-run <run id>")


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
    """The width is one number now, and this is what keeps it that way.

    It used to be two: a literal matrix and a literal `/M` beside it, proved
    equal by comparing them. #1344 removed the pair, so comparing them is no
    longer possible and would not mean anything if it were. What can still go
    wrong is the denominator being pinned to a number of its own again while
    the matrix comes from the gate, so that is what this refuses: split six
    ways while told it is four, two shards prove the same entries twice and a
    third of the registry goes unproven with every shard green (L41).

    The other half, that the gate's `count` really is the width it asked
    about, is a behaviour test in
    tests/test_the_sweep_runs_only_the_due_shards.py: it cannot be seen from
    the workflow text at all.
    """
    # Through without_prose: the comments in guards.yml name every
    # construct below, and a guard reading raw text is answered by the
    # prose about a rule as readily as by the rule (L103, L135).
    text = without_prose(WORKFLOW)

    assert not re.search(r"--shard \$\{\{ matrix\.shard \}\}/\d", text), (
        "check_guards is told a literal number of shards again, so it can "
        "disagree with the matrix the gate expands")
    assert "--shard ${{ matrix.shard }}/${{ needs.due.outputs.count }}" in text, (
        "the denominator does not come from the gate that also builds the "
        "matrix, so the two are separate readings of the width again")
