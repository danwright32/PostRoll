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


class NoSweepFound(Exception):
    """No sweep could be named to record from. Distinct from a sweep that found
    nothing, which would read as a healthy record (L98)."""


#: Which workflow the readings come from.
#:
#: Never the per-pull-request `changed` job, which proves only the entries one
#: diff touched: the workflow admits scheduled and hand-started runs only, and
#: which shards a run actually proved decides whether it replaces the record or
#: is folded into it (#1467).
SWEEP_WORKFLOW = "guards.yml"


def newest_sweep_run(find=None) -> str:
    """The newest guards.yml run that actually swept, as a run id.

    For the manual trigger. Read from the run history per event, scheduled and
    hand-started, through the same helper the daily run uses, because since
    #1428 only a hand-started run sweeps and "the newest successful scheduled
    run" is one that swept nothing (#1467).

    Every way of not finding one is its own refusal rather than an empty
    answer, because the caller acts on the answer (L11, L98).
    """
    if find is None:
        from tools.guard_sweep_history import newest_full_sweep

        def find():
            # Successful runs only, as the workflow follows: a failed run's
            # readings stop wherever it died (L331).
            return newest_full_sweep(require_success=True)
    from tools.guard_sweep_history import HistoryUnreadable
    try:
        sweep = find()
    except HistoryUnreadable as exc:
        raise NoSweepFound(
            f"the guard sweep's run history could not be read ({exc}). That is "
            "not the same as there being no sweep") from exc
    if sweep is None:
        raise NoSweepFound(
            f"no run of {SWEEP_WORKFLOW} in the recent scheduled or hand-started "
            "history proved a shard, so there is nothing to record from. Start "
            "a sweep with `gh workflow run guards.yml`")
    return str(sweep.run_id)


def record_from_run(run_id: str, record_path: Path, *, sweep_of=None,
                    fetch=None) -> int:
    """Record from the one run the workflow followed (#1467).

    Three outcomes, said apart. A run that swept nothing has nothing to record,
    and says so and exits 0: that is the ordinary daily run since #1428, and
    it must not read as a failing workflow (L36). A run that proved every shard
    replaces the record. A run that proved some shards, which #1344 made the
    usual hand-started sweep, is folded into the record rather than replacing
    it, since replacing would price the registry from a fraction of it. Any
    failure to read or record a run that did sweep is raised, so the workflow
    goes red rather than standing still in green (L289).
    """
    from tools.check_guard_sweep_due import SHARD_COUNT
    from tools.guard_sweep_history import HistoryUnreadable
    if sweep_of is None:
        from tools.guard_sweep_history import sweep_of
    if fetch is None:
        fetch = fetch_run
    try:
        sweep = sweep_of(run_id)
    except HistoryUnreadable as exc:
        raise SystemExit(
            f"which shards run {run_id} proved could not be read: {exc}. "
            "Nothing was written.") from exc
    if not sweep.passed_shards:
        print(f"run {run_id} did not sweep, so there is nothing to record. "
              "The full sweep runs only when started by hand.")
        return 0
    with tempfile.TemporaryDirectory() as scratch:
        paths = fetch(run_id, Path(scratch))
        if sweep.passed_shards >= frozenset(range(1, SHARD_COUNT + 1)):
            return _whole(paths, record_path)
        which = ", ".join(str(n) for n in sorted(sweep.passed_shards))
        print(f"run {run_id} swept shard(s) {which} of {SHARD_COUNT}, so its "
              "readings are folded into the record rather than replacing it")
        return _add(paths, record_path)


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




def _refuse_a_partial_sweep(paths: list[Path]) -> None:
    """Every shard of the sweep, or nothing is written (#1344).

    Only `_whole` asks this. `--add` scales a LATER, deliberately partial
    reading onto an existing record and is supposed to take a subset; `_whole`
    REPLACES the record, on the stated grounds that a whole sweep IS the
    registry, and that is the one this can be wrong about.

    #1344 made a sweep able to run only the shards with something to prove, so
    a run can now upload one artifact out of seven. Replacing the record from
    it would price the whole registry from a seventh of it: every reading in
    that file is correct and there are simply far fewer of them, which is
    exactly why nothing in the contents says so (L288: judge a run by the count
    it EXECUTED against the count expected, before reading anything in it).

    The artifacts say how wide the sweep was themselves, as `N/M`, so this
    needs no second copy of the shard count to compare against (L70).
    """
    splits = []
    for path in paths:
        payload = json.loads(path.read_text(encoding="utf-8"))
        splits.append((path, str(payload.get("shard") or "")))

    declared = [(path, split) for path, split in splits if split]
    if not declared:
        # Every artifact predates #1090, which is the only way to have none:
        # nothing written since carries no shard. There is no width to check
        # against, and refusing would make every older reading unusable, which
        # is the tolerance test_a_file_written_before_the_field_existed_is
        # _accepted records. Said out loud rather than passed silently (L98).
        print("none of these readings says which shard it came from, so "
              "whether this is a whole sweep could not be established. They "
              "predate #1090.")
        return
    if len(declared) != len(splits):
        raise SystemExit(
            f"{len(splits) - len(declared)} of these {len(splits)} readings do "
            "not say which shard they came from and the rest do, so they are "
            "not the shards of one sweep. Nothing was written.")

    widths = set()
    seen: dict[int, Path] = {}
    for path, split in declared:
        index, _, width = split.partition("/")
        try:
            widths.add(int(width))
            seen[int(index)] = path
        except ValueError:
            raise SystemExit(
                f"{path} records its shard as {split!r}, which is not an N/M "
                "split, so its place in the sweep cannot be read. Nothing was "
                "written.") from None

    if len(widths) > 1:
        raise SystemExit(
            f"these readings come from sweeps split {sorted(widths)} ways, so "
            "they are not the shards of one sweep and counting them would be "
            "satisfied by any two of them. Nothing was written.")

    width = widths.pop()
    missing = sorted(set(range(1, width + 1)) - set(seen))
    if missing:
        raise SystemExit(
            f"this is {len(seen)} shard(s) of a sweep split {width} ways: "
            f"shard(s) {', '.join(str(m) for m in missing)} are absent. The "
            "record replaces itself from a whole sweep, so recording these "
            "would price the entire registry from the fraction that ran, and "
            "every reading in them is correct which is why nothing in their "
            "contents would say so. Re-run the sweep with every shard, by "
            "dispatching it against a tree none of them has proved. Nothing "
            "was written.")


#: How many readings each figure in this record came from (#1328).
#:
#: A sweep measures each entry ONCE, so 1 is the honest answer everywhere here,
#: and `runs: 1` is a fine one: the point is not that a figure was taken many
#: times, it is that a reader can tell one reading from a median of six.
RUNS_PER_FIGURE = 1

#: Said by the tool that writes the record, never added to the file afterwards.
#:
#: `write` rewrites the record whole in BOTH modes, so a hand edit does not
#: survive the next recording. #1332 added `runs` and `_sample` to this fixture
#: by hand and updated only `tools/record_test_durations.py`; the next scheduled
#: sweep dropped them and the sample guard went red on the recording PR, which
#: is L379 exactly: doing by hand what a tool normally does performs the visible
#: change and omits the tool's other writes.
#:
#: It deliberately does NOT name a run. "Every figure here comes from ONE sweep,
#: run <id>" is true of a `--from` record and false the moment `--add` folds a
#: second run in, and a note is read as a measurement, so it may only claim what
#: holds in both modes (L210). Which run each reading came from is already
#: recorded per entry under `measured`.
SAMPLE_NOTE = (
    "Every figure here is ONE reading: a sweep measures each entry once, so "
    "runs is 1. Which run a reading came from is under `measured`, and the "
    "`shard` on a cold entry says which shard it ran on, not how many times it "
    "was measured (#1328).")


def write(record: dict, path: Path) -> None:
    stated = {**record, "runs": RUNS_PER_FIGURE, "_sample": SAMPLE_NOTE}
    path.write_text(json.dumps(stated, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def _whole(paths: list[Path], record_path: Path) -> int:
    """One sweep's readings, replacing the record.

    Replacing rather than merging, because a whole sweep IS the registry: an
    entry it does not hold is one the registry no longer has, and keeping it
    would leave the deal pricing guards that were deleted.
    """
    _refuse_a_partial_sweep(paths)
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


def describe(record_path: Path) -> str:
    """When the record was last replaced, for the run's summary (#1467).

    Said on every run, so a record that has stopped moving is visible rather
    than inferred. Never raises: it runs in the step that reports what happened,
    and a crash there would hide the report it exists to give.
    """
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return f"The guard cost record could not be read: {error}"
    return (f"The record was last replaced from a whole sweep on "
            f"{record.get('measured_on')}, run {record.get('measured_from_run')}. "
            "Partial sweeps since are folded in per entry.")


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
    parser.add_argument("--from-newest-run", dest="newest", action="store_true",
                        help="find the newest guards.yml run that actually "
                             "swept and record from it")
    parser.add_argument("--from-upstream-run", dest="upstream", default=None,
                        help="the guards.yml run the workflow followed: record "
                             "from it if it swept, say so if it did not")
    parser.add_argument("--describe", action="store_true",
                        help="say when the record was last replaced, and nothing else")
    parser.add_argument("--record", type=Path, default=RECORD)
    args = parser.parse_args(argv)

    if args.describe:
        print("\n" + describe(args.record))
        return 0

    asked = [bool(args.whole), bool(args.add), bool(args.run_id),
             bool(args.newest), bool(args.upstream)]
    if sum(asked) != 1:
        parser.error(
            "say exactly one of --from, --add, --from-run, --from-newest-run "
            "or --from-upstream-run")

    if args.upstream:
        return record_from_run(args.upstream, args.record)

    if args.newest:
        try:
            run_id = newest_sweep_run()
        except NoSweepFound as refusal:
            print(refusal)
            return 1
        print(f"recording from run {run_id}, the newest {SWEEP_WORKFLOW} run "
              "that actually swept")
        return record_from_run(run_id, args.record)

    if args.run_id:
        with tempfile.TemporaryDirectory() as scratch:
            return _whole(fetch_run(args.run_id, Path(scratch)), args.record)

    if args.whole:
        return _whole(args.whole, args.record)

    return _add(args.add, args.record)


def _add(paths: list[Path], record_path: Path) -> int:
    """A later, partial run's readings, scaled onto the existing record."""
    seconds, kinds, cold, run = readings_of(paths)
    existing = json.loads(record_path.read_text(encoding="utf-8")) \
        if record_path.exists() else {"seconds": {}, "measured": {}}
    record = added(existing, seconds, run, noun=NOUN)
    record["kinds"] = dict(sorted({**(existing.get("kinds") or {}), **kinds}.items()))
    record["cold"] = (existing.get("cold") or []) + cold
    for key in ("measured_on", "measured_from_run", "re_measure_with"):
        if key in existing:
            record[key] = existing[key]
    write(record, record_path)
    new = sorted(set(record["seconds"]) - set(existing.get("seconds") or {}))
    print(f"added {len(new)} entries from run {run}")
    for name in new:
        print(f"  {name}: {record['seconds'][name]}s "
              f"(scaled {record['measured'][name]['scale']}x)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
