#!/usr/bin/env python3
"""Recorded durations that never said how many runs produced them (#1328).

#1245 made every recorded duration name the MACHINE it came from, because the
two machines here differ by 4x. That was necessary and it is not sufficient.

Measured on 2026-09-04, two dispatched runs of identical code on the same
macos-26 runner came out at 183.4s and 157.5s, a spread of at least 16.5%. So a
figure that names its machine and not its sample size is still unreadable: a
difference smaller than that spread reads as a result. #1257 was reported as a
10.8% improvement on exactly that basis, from one reading per arm, and the
claim had to be withdrawn.

## What counts as saying it

Any of these, on the block itself or on one containing it:

`runs`, `passes` or `samples`, on the block itself or on one containing it.
That is the whole rule, and it is deliberately not clever.

A list's LENGTH was tried as an implicit answer and is wrong: the two entries
of `swift_suite_cost.json`'s `readings` are two different machines, not two
readings of one figure, and `guard_sweep_timing.json`'s four `shard_seconds`
are four shards of a single run. Both would have reported a sample of the wrong
size, which is worse than reporting none (L11).

`runs: 1` is a perfectly good answer. The point is not that a figure was taken
many times, it is that a reader can tell. A single reading honestly labelled is
worth more than a median whose sample nobody recorded, because the first can be
argued with (L316).

## What it does NOT do

It does not check that a figure is still true, and it does not require a
minimum sample. Both would be a different tool, and a threshold on sample size
here would fail every honest single reading in the repository.

    venv/bin/python tools/check_figures_say_their_sample.py
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

#: The fixtures that RECORD measurements, named rather than matched.
#:
#: Named because "a file with a seconds key in it" also catches the shared
#: contract fixtures, whose numbers are a specification the code must satisfy
#: rather than a reading anybody took: `collage_gutter.json` says what the gutter
#: MUST be, and asking it how many runs produced that is a category error.
MEASUREMENT_FIXTURES = (
    "alt_text_call_timing.json",
    "changed_job_timing.json",
    "guard_entry_costs.json",
    "guard_sweep_timing.json",
    "swift_suite_cost.json",
    "test_file_durations.json",
)

#: A key whose value is a duration somebody measured.
DURATION_SUFFIXES = ("_seconds", "_ms", "_seconds_at_least")
DURATION_KEYS = {"seconds", "wall_seconds", "elapsed", "step", "compiling",
                 "running"}

#: Durations that are a LIMIT somebody chose rather than a reading anybody took.
#:
#: A deadline is not a measurement, so asking how many runs produced it has no
#: answer. Listed by exact name rather than by a pattern, because the difference
#: is what the number MEANS and no spelling carries that.
CHOSEN_NOT_MEASURED = {"deadline_seconds", "timeout_seconds", "budget_seconds",
                       "interval_seconds"}

#: A key that says how many readings a figure came from.
SAMPLE_KEYS = {"runs", "passes", "samples"}


class CannotRead(Exception):
    """A fixture could not be read, which is not the same as it being clean."""


@dataclass(frozen=True)
class Unsourced:
    """One block stating a duration without saying what it was measured over."""

    file: str
    where: str
    figures: tuple[str, ...]


def _is_duration(key: str, value: object) -> bool:
    if key in CHOSEN_NOT_MEASURED:
        return False
    if not (key in DURATION_KEYS or key.endswith(DURATION_SUFFIXES)):
        return False
    if isinstance(value, bool):
        return False
    # A list of durations is as much a recorded figure as a single one, and it
    # is the shape most likely to be mistaken for its own sample size.
    if isinstance(value, list):
        return any(isinstance(item, (int, float)) and not isinstance(item, bool)
                   for item in value)
    # And so is a MAPPING of durations. `test_file_durations.json` records one
    # per test file under a single `seconds` key, and reading only numbers and
    # lists let the largest recorded set of durations in the repository escape
    # this entirely.
    if isinstance(value, dict):
        return bool(value) and all(
            isinstance(item, (int, float)) and not isinstance(item, bool)
            for item in value.values())
    return isinstance(value, (int, float))


def scanned_files(root=None) -> list[Path]:
    """Every fixture this reads, in a stable order."""
    base = Path(root) if root is not None else REPO_ROOT / "tests" / "fixtures"
    return [base / name for name in MEASUREMENT_FIXTURES if (base / name).is_file()]


def _walk(node: object, where: str, sampled: bool, found: list[Unsourced],
          file: str) -> None:
    if isinstance(node, list):
        # Walked, but a list confers NO sample size on what is inside it: see
        # the docstring for the two shapes where its length is the wrong answer.
        for index, item in enumerate(node):
            _walk(item, f"{where}[{index}]", sampled, found, file)
        return
    if not isinstance(node, dict):
        return

    here = sampled or any(
        key in node and isinstance(node[key], int) and not isinstance(node[key], bool)
        for key in SAMPLE_KEYS)

    figures = tuple(sorted(key for key, value in node.items()
                           if _is_duration(key, value)))
    if figures and not here:
        found.append(Unsourced(file=file, where=where or "(root)", figures=figures))

    for key, value in node.items():
        _walk(value, f"{where}.{key}" if where else key, here, found, file)


def unsourced(root=None) -> list[Unsourced]:
    """Every recorded duration that does not say how many runs it came from."""
    found: list[Unsourced] = []
    for path in scanned_files(root=root):
        try:
            loaded = json.loads(path.read_text())
        except (json.JSONDecodeError, UnicodeDecodeError) as bad:
            raise CannotRead(f"{path.name} could not be read: {bad}") from bad
        _walk(loaded, "", False, found, path.name)
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Find recorded durations that "
                                                 "do not say their sample size.")
    parser.add_argument("--root", default=None,
                        help="read fixtures from this directory instead")
    args = parser.parse_args(argv)

    try:
        found = unsourced(root=args.root)
    except CannotRead as refusal:
        print(f"nothing checked: {refusal}")
        return 2

    if not found:
        print("every recorded duration says how many runs it came from")
        return 0

    print(f"{len(found)} block(s) state a duration without saying what it was "
          f"measured over:")
    for block in found:
        print(f"  {block.file} at {block.where}: {', '.join(block.figures)}")
    print("\nAdd `runs` (or `passes`) beside the figure. `runs: 1` is a fine "
          "answer:\nwhat matters is that a reader can tell one reading from a "
          "median of six.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
