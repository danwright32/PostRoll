#!/usr/bin/env python3
"""Write down what each guard registry entry costs to re-prove (#1090).

`tools/check_guards.py --timings PATH` writes one run's readings. This folds
them into `tests/fixtures/guard_entry_costs.json`, which is what `shard_of`
deals by and what `tests/test_guard_sweep_fits_its_deadline.py` projects the
largest shard from.

Two modes, the same pair `tools/record_test_durations.py` has:

    tools/record_guard_costs.py --from shard-1.json shard-2.json ...
        One sweep's shards, replacing the record. Every reading came from the
        same sweep, so nothing needs scaling and every entry is stamped with
        that run.

    tools/record_guard_costs.py --add later.json
        A run that measured some entries the record has never seen, plus some
        it has. The ones it already knows are the references: their ratio puts
        this run's readings on the record's own run, and the entries already in
        the record KEEP the readings they had, because re-writing them from a
        different run is the churn #1038 exists to avoid.

The shape and the scaling are `tools/measured_record.py`, shared with the test
file record rather than cloned, so a refusal added to one is not missing from
the other (L41).

Refusals, all of them loud and none of them a zero:

* a readings file with no `seconds` at all, which would write an empty record,
  and an empty record deals every entry as free (L98);
* a `--from` set whose files disagree about which RUN they came from, because
  two sweeps' readings averaged together are a number from neither (L224);
* an entry measured at zero, which is a reading that cannot be right for a
  perturbation that applied, ran a test and restored a file.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tools.measured_record import Provenance, added  # noqa: E402
from tools.guard_entry_costs import RECORD  # noqa: E402

NOUN = "guard entry"


def readings_of(paths: list[Path]) -> tuple[dict[str, float], str]:
    """Every reading in `paths`, and the one run they all came from.

    A disagreement about the run is refused rather than resolved. Shards of one
    sweep carry the same run id; two different sweeps carry two, and folding
    those into one record makes a number that describes neither run, with
    nothing in the record saying so (L224).
    """
    seconds: dict[str, float] = {}
    runs: set[str] = set()
    for path in paths:
        if not path.exists():
            raise SystemExit(f"{path} does not exist. Nothing was written.")
        payload = json.loads(path.read_text(encoding="utf-8"))
        found = payload.get("seconds") or {}
        if not found:
            raise SystemExit(
                f"{path} holds no readings. An empty record deals every entry "
                "as free, which is a partition that looks balanced and is not. "
                "Nothing was written.")
        runs.add(str(payload.get("run") or "unknown"))
        for name, value in found.items():
            reading = float(value)
            if reading <= 0:
                raise SystemExit(
                    f"{path} records {name} at {reading}s, which cannot be "
                    "right for an entry that applied a perturbation, ran a "
                    "test and restored the file. Nothing was written.")
            if name in seconds:
                raise SystemExit(
                    f"{name} is measured in more than one of these files. "
                    "Every entry lands in exactly one shard, so two readings "
                    "means these are not the shards of one sweep. Nothing was "
                    "written.")
            seconds[name] = reading
    if len(runs) > 1:
        raise SystemExit(
            f"these readings come from {len(runs)} different runs "
            f"({', '.join(sorted(runs))}). Readings taken under different load "
            "cannot be averaged into one record without saying so, which is "
            "the whole point of stamping them. Nothing was written.")
    return seconds, runs.pop()


def write(record: dict, path: Path) -> None:
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--from", dest="whole", nargs="+", type=Path,
                        default=None,
                        help="one sweep's readings files, replacing the record")
    parser.add_argument("--add", nargs="+", type=Path, default=None,
                        help="a later run's readings, scaled onto the record")
    parser.add_argument("--record", type=Path, default=RECORD)
    args = parser.parse_args(argv)

    if bool(args.whole) == bool(args.add):
        parser.error("say either --from (a whole sweep) or --add (a later run)")

    if args.whole:
        seconds, run = readings_of(args.whole)
        record = {
            "seconds": {name: round(value, 2)
                        for name, value in sorted(seconds.items())},
            "measured": Provenance.full(run, sorted(seconds)),
        }
        write(record, args.record)
        print(f"recorded {len(seconds)} entries from run {run}")
        return 0

    seconds, run = readings_of(args.add)
    existing = json.loads(args.record.read_text(encoding="utf-8")) \
        if args.record.exists() else {"seconds": {}, "measured": {}}
    record = added(existing, seconds, run, noun=NOUN)
    write(record, args.record)
    new = sorted(set(record["seconds"]) - set(existing.get("seconds") or {}))
    print(f"added {len(new)} entries from run {run}")
    for name in new:
        print(f"  {name}: {record['seconds'][name]}s "
              f"(scaled {record['measured'][name]['scale']}x)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
