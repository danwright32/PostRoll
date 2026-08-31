"""What each guard registry entry costs to re-prove (#1090).

Nothing recorded this. `check_guards` printed elapsed-since-start rather than
per-entry cost and stored neither, so the two things that need the number could
not have it:

* `shard_of` dealt entries round robin WITHIN two cost classes, Swift and
  Python. That is a proxy for cost, not a measure of it (L63, L296), and the
  classes are wide: measured over ten `changed` runs the real rate ran from
  1,174ms to 106,500ms per entry, a factor of 90, because a Swift entry rebuilds
  the app at about 29s and a Python one is under a second.
* `tools/check_job_durations.py` leaves the guard jobs NOT_NORMALISED, because
  their logs report `N guards checked` and dividing by a count of items whose
  costs differ by 90x would hand a bare comparison the confidence of a measured
  one, which is the defect #1041 exists to remove.

The number that sized the deadline guard had to be reversed out of one sweep
run: 14.4s per entry averaged across 469 of them, which hides all of the above.

The record is `tests/fixtures/guard_entry_costs.json`, in the same shape as
`tests/fixtures/test_file_durations.json`: a `seconds` map, and a `measured` map
saying WHICH run each reading came from, so readings taken on different runners
or at different times are not silently mixed (L224, #1038).

Every reader here RAISES rather than answering with an empty or zero cost. An
entry recorded as costing nothing is dealt into a shard as free, and a whole
record read as empty deals every entry as free, which is a partition that looks
balanced and is not (L98, L10).
"""

from __future__ import annotations

import json
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Sequence

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORD = REPO_ROOT / "tests" / "fixtures" / "guard_entry_costs.json"

#: The prefix that says an entry is proved by xcodebuild rather than by pytest.
#: The one thing known about an UNMEASURED entry, and therefore the only basis
#: on which one can be estimated.
SWIFT_TEST_PREFIX = "PostRollTests/"


class CostRecordError(Exception):
    """The record cannot answer. Never a zero, never an empty map."""


@dataclass(frozen=True)
class Costs:
    """What each entry costs, and how much of that was actually measured.

    The second half is not decoration. An estimate and a reading deal into a
    shard identically, so without a count of estimates a record covering three
    entries out of five hundred produces a confident looking partition of
    almost entirely guessed numbers (L11, L98).
    """

    seconds: Mapping[str, float]
    estimated: frozenset[str]

    def of(self, name: str) -> float:
        try:
            return self.seconds[name]
        except KeyError as missing:  # pragma: no cover - guarded by callers
            raise CostRecordError(
                f"no cost for {name!r}, so it would be dealt as free"
            ) from missing

    @property
    def measured(self) -> int:
        return len(self.seconds) - len(self.estimated)


def read_record(path: Path | None = None) -> dict:
    """The record as written, or a refusal naming what is wrong.

    `path` defaults to `RECORD` at CALL time, not at definition time, so a test
    can point the module at a record it owns. A default bound at definition time
    is a dependency the function constructs for itself, which no caller and no
    test can replace (L196), and the test that tries reads the live record while
    reporting on its own fixture.

    Absent, unparseable and empty are three different failures and each says so
    in its own words, because the remedy differs: write the record, fix it, or
    run a sweep that measures something (L11).
    """
    path = path if path is not None else RECORD
    if not path.exists():
        raise CostRecordError(
            f"{path} does not exist, so nothing knows what a guard entry costs. "
            "Record one from a sweep: tools/record_guard_costs.py --from <file>"
        )
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as bad:
        raise CostRecordError(f"{path} is not readable JSON: {bad}") from bad
    seconds = record.get("seconds")
    if not isinstance(seconds, dict) or not seconds:
        raise CostRecordError(
            f"{path} holds no readings, and an empty record deals every entry "
            "as free, which is a partition that looks balanced and is not"
        )
    return record


def costs_for(names_by_kind: Mapping[str, bool],
              path: Path | None = None) -> Costs:
    """A cost for every entry, measured where there is a reading and estimated
    where there is not.

    `names_by_kind` maps entry name to whether it is proved by xcodebuild.

    An unmeasured entry takes the MEDIAN of the measured entries of its own kind,
    never zero and never the overall median. The two kinds differ by about 90x,
    so one pooled median would price a new Swift entry at a fraction of its cost
    and hand whichever shard receives it far more work than the deal intended
    (L117, L296).

    A kind with no readings at all is a refusal rather than a fallback to the
    other kind's median, which would be the same 90x error wearing a reason.
    """
    record = read_record(path)
    was = record.get("kinds") or {}
    recorded: dict[str, float] = {}
    for name, value in record["seconds"].items():
        # A reading is only valid for the KIND it was taken as. #1089 moved
        # seven entries from a Swift test to a Python one, and their readings
        # went on saying 29s for something that now costs 0.2s: an entry that
        # changes kind changes cost by about 90x, and nothing in a bare
        # name-to-seconds map can tell that from an entry that got slower
        # (L133). Discarded rather than kept, so it is re-estimated from the
        # median of the kind it is now and re-measured by the next sweep.
        if name in was and name in names_by_kind and was[name] != names_by_kind[name]:
            continue
        recorded[name] = float(value)

    medians: dict[bool, float] = {}
    for swift in (True, False):
        readings = [
            seconds
            for name, seconds in recorded.items()
            if names_by_kind.get(name) is swift and seconds > 0
        ]
        if readings:
            medians[swift] = statistics.median(readings)

    seconds: dict[str, float] = {}
    estimated: set[str] = set()
    for name, swift in names_by_kind.items():
        reading = recorded.get(name)
        if reading is not None and reading > 0:
            seconds[name] = reading
            continue
        if swift not in medians:
            kind = "Swift" if swift else "Python"
            raise CostRecordError(
                f"{name} has no recorded cost and no {kind} entry in the record "
                "has one either, so there is nothing to estimate it from. "
                "Estimating it from the other kind would be wrong by about 90x, "
                "and estimating it as free would deal it into a shard as free."
            )
        seconds[name] = medians[swift]
        estimated.add(name)

    return Costs(seconds=seconds, estimated=frozenset(estimated))


def deal(names: Sequence[str], total: int, cost: Mapping[str, float]) -> list[list[str]]:
    """`names` split `total` ways, balanced by measured cost, largest first.

    Longest-processing-time-first: take the entries in descending cost and give
    each to whichever shard is currently cheapest. It is the standard greedy
    partition and it is within 4/3 of optimal, which is far better than the
    round robin it replaces: that one balanced the COUNT of expensive entries,
    and two Swift entries are not the same amount of work (L63, L296).

    Ties broken by name so the deal is the same on every runner and in every
    test. A partition that depends on dictionary order would put an entry on a
    different shard from one run to the next, and the shard that reports what it
    did NOT run would then be describing a different set each time.

    Every entry lands in exactly one shard, which is the property the whole
    split rests on: a partition that drops one leaves every shard green and that
    guard unproven, with nothing anywhere mentioning it (L98).
    """
    if total < 1:
        raise ValueError(f"a sweep cannot be split {total} ways")
    if total > len(names):
        raise ValueError(
            f"a {total} way split of {len(names)} entries leaves at least one "
            "runner with nothing to prove, and a green run that checked "
            "nothing reads exactly like a clean sweep"
        )

    shards: list[list[str]] = [[] for _ in range(total)]
    loads = [0.0] * total
    for name in sorted(names, key=lambda n: (-cost[n], n)):
        lightest = min(range(total), key=lambda i: (loads[i], i))
        shards[lightest].append(name)
        loads[lightest] += cost[name]
    return shards


def imbalance(shards: Iterable[Sequence[str]], cost: Mapping[str, float]) -> float:
    """The heaviest shard's cost divided by the mean, 1.0 being a perfect deal.

    Measured in the same unit the deal is made in, so the check cannot pass
    while measuring something else (L63, L296).
    """
    loads = [sum(cost[name] for name in shard) for shard in shards]
    if not loads or not sum(loads):
        raise CostRecordError(
            "every shard costs nothing, so this ratio is 0/0 and would report a "
            "perfect balance of a deal that measured nothing"
        )
    return max(loads) / (sum(loads) / len(loads))
