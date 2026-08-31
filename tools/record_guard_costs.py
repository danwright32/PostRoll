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

    tools/record_guard_costs.py --from-run <workflow run id>
        The same as `--from`, with the shards' artifacts fetched from that run
        of guards.yml first. This is the form a person actually types, and it
        exists because the other one is a rule living in a comment: the daily
        sweep uploads its readings and nothing folds them in, so without one
        command that does the whole thing the record ages until a guard says so
        and then the remedy is four manual steps (L27, L111).

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
import subprocess
import time
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tools.measured_record import Provenance, added  # noqa: E402
from tools.guard_entry_costs import RECORD  # noqa: E402

NOUN = "guard entry"


def readings_of(paths: list[Path]) -> tuple[dict[str, float], dict[str, bool],
                                            list[dict], str]:
    """Every reading in `paths`, and the one run they all came from.

    A disagreement about the run is refused rather than resolved. Shards of one
    sweep carry the same run id; two different sweeps carry two, and folding
    those into one record makes a number that describes neither run, with
    nothing in the record saying so (L224).
    """
    seconds: dict[str, float] = {}
    kinds: dict[str, bool] = {}
    cold: list[dict] = []
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
        left = payload.get("unproven") or []
        if left:
            raise SystemExit(
                f"{path} comes from a shard that ran out of time with "
                f"{len(left)} entries never reached, so it measured part of its "
                "share and nothing about the rest. Its readings are all correct "
                "and there are simply fewer of them, which is why nothing in the "
                "file's contents would say so. Re-run the sweep, or raise its "
                "deadline, before recording. Nothing was written.")
        runs.add(str(payload.get("run") or "unknown"))
        if payload.get("cold"):
            cold.append({**payload["cold"], "shard": payload.get("shard", "")})
        recorded_kinds = payload.get("kinds") or {}
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
            if name in recorded_kinds:
                kinds[name] = bool(recorded_kinds[name])
    if len(runs) > 1:
        raise SystemExit(
            f"these readings come from {len(runs)} different runs "
            f"({', '.join(sorted(runs))}). Readings taken under different load "
            "cannot be averaged into one record without saying so, which is "
            "the whole point of stamping them. Nothing was written.")
    return seconds, kinds, sorted(cold, key=lambda c: c["entry"]), runs.pop()


def fetch_run(run_id: str, into: Path) -> list[Path]:
    """Every `guard-timings-*` artifact of one guards.yml run, downloaded.

    Refuses an empty download rather than writing an empty record. A run whose
    shards all SKIPPED (the tree was already proved) uploads nothing, and that
    is a different thing from a run that measured nothing: recording either as
    the sweep's cost prices the registry from a sweep that never happened
    (L98, L331).
    """
    try:
        subprocess.run(
            ["gh", "run", "download", str(run_id), "--pattern", "guard-timings-*",
             "--dir", str(into)],
            check=True, capture_output=True, text=True)
    except FileNotFoundError as missing:
        raise SystemExit(
            "the gh CLI is not on PATH, so the artifacts cannot be fetched. "
            "Download them by hand and use --from. Nothing was written."
        ) from missing
    except subprocess.CalledProcessError as failed:
        raise SystemExit(
            f"gh could not download run {run_id}: "
            f"{failed.stderr.strip() or failed.stdout.strip()}. "
            "Nothing was written."
        ) from failed

    found = sorted(into.rglob("guard-timings-*.json"))
    if not found:
        raise SystemExit(
            f"run {run_id} carries no guard-timings artifact. Either its shards "
            "skipped, because the tree was already proved, or it predates "
            "#1090. Pick a run whose sweep actually ran. Nothing was written.")
    return found


def write(record: dict, path: Path) -> None:
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def _whole(paths: list[Path], record_path: Path) -> int:
    """One sweep's readings, replacing the record.

    Replacing rather than merging, because a whole sweep IS the registry: an
    entry it does not hold is one the registry no longer has, and keeping it
    would leave the deal pricing guards that were deleted.
    """
    seconds, kinds, cold, run = readings_of(paths)
    write({
        "seconds": {name: round(value, 2)
                    for name, value in sorted(seconds.items())},
        # Which KIND each reading was taken as, so a reading survives only as
        # long as the entry it describes is still proved the same way. An entry
        # moved from a Swift test to a Python one costs about 1/90th of what it
        # did, and a bare seconds map cannot tell that from an entry that got
        # faster (L133).
        "kinds": dict(sorted(kinds.items())),
        # What the cold app build cost each shard, carried through rather than
        # left in the CI artifact it arrived in. `write_timings` sets these
        # aside so they are not read as the entries' own cost, and the reason
        # given for keeping them at all is that they are the only measurement
        # anyone has of the build. An artifact expires, so a reading that stops
        # here would make that reason false in the one place it matters (L46,
        # L202). #1096 is the issue that would remove the need for them.
        "cold": cold,
        "measured": Provenance.full(run, sorted(seconds)),
        "measured_on": time.strftime("%Y-%m-%d"),
        "measured_from_run": run,
        "re_measure_with": (
            "tools/record_guard_costs.py --from-run <the newest guards.yml run "
            "whose shards actually swept>"),
    }, record_path)
    print(f"recorded {len(seconds)} entries from run {run}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--from", dest="whole", nargs="+", type=Path,
                        default=None,
                        help="one sweep's readings files, replacing the record")
    parser.add_argument("--add", nargs="+", type=Path, default=None,
                        help="a later run's readings, scaled onto the record")
    parser.add_argument("--from-run", dest="run_id", default=None,
                        help="a guards.yml run id, whose shard artifacts are "
                             "downloaded and then treated as --from")
    parser.add_argument("--record", type=Path, default=RECORD)
    args = parser.parse_args(argv)

    asked = [bool(args.whole), bool(args.add), bool(args.run_id)]
    if sum(asked) != 1:
        parser.error("say exactly one of --from, --add or --from-run")

    if args.run_id:
        with tempfile.TemporaryDirectory() as scratch:
            return _whole(fetch_run(args.run_id, Path(scratch)), args.record)

    if args.whole:
        return _whole(args.whole, args.record)

    seconds, kinds, cold, run = readings_of(args.add)
    existing = json.loads(args.record.read_text(encoding="utf-8")) \
        if args.record.exists() else {"seconds": {}, "measured": {}}
    record = added(existing, seconds, run, noun=NOUN)
    record["kinds"] = dict(sorted({**(existing.get("kinds") or {}), **kinds}.items()))
    record["cold"] = (existing.get("cold") or []) + cold
    for key in ("measured_on", "measured_from_run", "re_measure_with"):
        if key in existing:
            record[key] = existing[key]
    write(record, args.record)
    new = sorted(set(record["seconds"]) - set(existing.get("seconds") or {}))
    print(f"added {len(new)} entries from run {run}")
    for name in new:
        print(f"  {name}: {record['seconds'][name]}s "
              f"(scaled {record['measured'][name]['scale']}x)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
