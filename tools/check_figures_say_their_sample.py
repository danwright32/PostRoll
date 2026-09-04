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

#: What makes a fixture a RECORD of something measured rather than a
#: SPECIFICATION of what the code must produce.
#:
#: This was a hand written list of six filenames, which is the trap this whole
#: tool exists to close, one level up: a new fixture recording timings was
#: exempt until somebody remembered to add its name, and exempt silently (L96,
#: #1337). Derived from the content instead, so a fixture cannot be missed by
#: being forgotten.
#:
#: The distinction is real and a wider glob would get it wrong. `collage_gutter`
#: and `crop_geometry` state numbers the code must SATISFY; asking those how
#: many runs produced them is a category error. What separates the two is that a
#: measurement says where it came from. Any one of these keys, at any depth, is
#: a file claiming to record something somebody went and measured.
PROVENANCE_KEYS = frozenset({
    "measured_on", "measured_from", "measured_from_run", "measured_at_commit",
    "re_measure_with", "machine", "runner_image", "runs", "passes", "samples",
})

#: Where the fixtures live.
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures"


def _every_key(node: object, found: set[str]) -> set[str]:
    if isinstance(node, dict):
        found |= set(node)
        for value in node.values():
            _every_key(value, found)
    elif isinstance(node, list):
        for value in node:
            _every_key(value, found)
    return found


def records_a_measurement(loaded: object) -> bool:
    """Whether this fixture claims to record something somebody measured."""
    return bool(_every_key(loaded, set()) & PROVENANCE_KEYS)

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
    """Every fixture that records a measurement, in a stable order.

    Decided by reading each file rather than by a list of names, so a fixture
    added tomorrow is covered the day it lands. A file that cannot be parsed is
    RAISED rather than skipped here, because a skipped file reads exactly like a
    clean one (L98).
    """
    base = Path(root) if root is not None else FIXTURE_DIR
    found = []
    for path in sorted(base.glob("*.json")):
        loaded = _load(path)
        # Either half is enough. Provenance alone brings in a record that has no
        # durations YET, so one added later is covered the day it lands. A
        # duration alone catches a file that states a reading and says nothing
        # about where it came from, which is the very thing this refuses and
        # would otherwise be invisible for lacking the keys that put it in
        # scope. Requiring provenance ALONE was tried first and opened exactly
        # that hole while closing another (L387).
        if records_a_measurement(loaded) or _holds_a_duration(loaded):
            found.append(path)
    return found


def _holds_a_duration(node: object) -> bool:
    """Whether anything anywhere in this fixture states a measured duration.

    Safe to use as scope here, measured rather than assumed: on 2026-09-04 every
    fixture in this repository holding a duration also carried provenance, and
    no specification fixture used a duration shaped key at all, so this widens
    the net without catching a single value that is a requirement rather than a
    reading.
    """
    if isinstance(node, dict):
        return any(_is_duration(key, value) or _holds_a_duration(value)
                   for key, value in node.items())
    if isinstance(node, list):
        return any(_holds_a_duration(value) for value in node)
    return False


def _load(path: Path):
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, UnicodeDecodeError) as bad:
        raise CannotRead(f"{path.name} could not be read: {bad}") from bad


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
        _walk(_load(path), "", False, found, path.name)
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
