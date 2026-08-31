#!/usr/bin/env python3
"""Measure what each test FILE costs, and write it down (#766).

`pytest.mark.slow` decides what `make test-python-fast` skips, and until now the
set carrying it was derived from `swift.yml`'s reference-frame matrix, on the
premise that the matrix is "where the time goes". That premise was never
measured, and it is wrong in both directions. Measured on 2026-08-21, as a share
of the whole run:

    test_frame_legibility.py            31.7%   in the matrix, marked slow
    test_golden_frames.py               21.2%   in the matrix, marked slow
    test_thursday_reel_legibility.py    17.3%   in the matrix, marked slow
    test_generate_media_friday_clips.py  3.3%   NOT in the matrix, not marked
    test_story_title_clamp.py            0.5%   in the matrix, marked slow

So the fast run was paying for a file nothing called slow while skipping one
seven times cheaper, because it happened to need macOS fonts. One marker was
naming two different properties: needing the system faces, and being expensive.
They are not the same property and a file can be either without being both.

This measures the second one directly. The record it writes is what
`tests/test_fast_subset_stays_honest.py` derives the slow set from, so the
derivation stays derived (L41) while measuring the thing it claims to.

    venv/bin/python tools/record_test_durations.py

It runs the whole suite, which takes a few minutes. Re-run it after adding a
file that ought to be slow, or after a change that moves what an existing one
costs; nothing else needs it, because a test file's cost does not drift on its
own.

A red suite is refused, because a file that failed did not run to completion and
its cost would be recorded as whatever it got through. There is one exception,
and it exists because without it this tool could not be run at the moment it is
needed (#837): the guards that READ the record live in
`tests/test_fast_subset_stays_honest.py`, they go red precisely when the record
has drifted, and each of them names this tool as the remedy. A remedy blocked by
the thing it exists to clear is the same as no remedy (L111), so an ASSERTION
failing in that one file no longer blocks the write, and the tool says out loud
which failures it recorded past.

The exception is deliberately narrower than "that file was red". An ERROR there,
or a file that failed to import, is not a guard reporting drift: it is a guard
whose verdict was never taken, and in the import case a file that contributed no
timings at all, which would silently leave the record short of it.

What it records is what pytest reports: summed per-test WALL time, under
`-n auto`. That is not CPU time and not a stable number of seconds. It moves
with how much contention the run had, which is a property of the machine and the
scheduler rather than of the test. Measured here twice on the same day, the same
suite on the same Mac, the second run under `--dist worksteal` (#783):

    test_frame_legibility.py      206.9s then 334.8s
    test_slider_program_plate.py   25.7s then  37.3s

The seconds moved by 60%; the SHARES of the run each file represents barely
moved at all. So the seconds are what is recorded, because they are the reading,
and `tests/file_durations.py` derives the share and compares against that. A
floor in seconds would have been crossed by four files with no test changing.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ElementTree
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORD = REPO_ROOT / "tests" / "fixtures" / "test_file_durations.json"

#: Every phase, not just `call`. A file whose cost is in an expensive fixture is
#: exactly as slow to run, and counting only the call would report it as cheap.
DURATION_LINE = re.compile(
    r"^\s*([\d.]+)s (?:call|setup|teardown)\s+(tests/test_[a-z0-9_]+\.py)::")

#: Files already in the record that `--add` measures beside a new one (#1038).
#:
#: Cheap, so the run is quick, and ORDINARY rather than expensive, because the
#: expensive files need ffmpeg and the macOS faces and a reference that skipped
#: would measure as free and give an infinite scale.
#:
#: Seven of them because the spread is wide. Measured on 2026-08-31 the
#: reference ratios ran 0.16 to 3.57, which is the same contention this whole
#: issue is about, and a median over seven survives one reference having a bad
#: run in a way a median over two does not.
REFERENCE_FILES = (
    "tests/test_build_cache_location.py",
    "tests/test_manifest_contract.py",
    "tests/test_wait_for_checks.py",
    "tests/test_make_test_runs_both_suites.py",
    "tests/test_swift_leg_meets_its_floor.py",
    "tests/test_record_suite_count.py",
    "tests/test_perturbation_lock.py",
)


# The record's shape and its scaling live in tools/measured_record.py since
# #1090, which needs the same thing for guard registry entries. Re-exported here
# because this module is where they were, and every caller and test names them
# through it (L41: one implementation, not two that drift).
from tools.measured_record import Provenance, added, scale_from  # noqa: E402,F401


#: The one file whose going red does not invalidate a measurement (#837).
#:
#: Every guard that READS this record lives there, and each of them names this
#: tool as the remedy for the drift it reports. Refusing to run while one of them
#: is red made that remedy unreachable, and the way through was a `--deselect`
#: written down nowhere (L111).
#:
#: Spelled as pytest's junit writer spells it, because that is what has to be
#: matched: under `-n` a testcase carries no `file` attribute at all, so the
#: dotted classname is the only thing saying which file a test came from.
#: `tests/test_record_test_durations.py` asks a real pytest run whether this is
#: still the spelling, rather than trusting it (L52).
OWN_GUARD_CLASSNAME = "tests.test_fast_subset_stays_honest"


@dataclass(frozen=True)
class FailedCase:
    """One testcase the run reported as red, and how it went red."""

    #: `failure` for an assertion inside the test, `error` for a test that never
    #: got that far: a fixture that blew up, or a file that would not import.
    kind: str
    classname: str
    name: str

    @property
    def identity(self) -> str:
        """How to name it to a person.

        A file that failed to IMPORT is reported with an EMPTY classname and the
        module path in `name` instead, so joining the two unconditionally would
        print a leading `::` on exactly the case worth reading carefully.
        """
        return f"{self.classname}::{self.name}" if self.classname else self.name

    @property
    def is_the_records_own_guard(self) -> bool:
        """Whether this is drift being reported, rather than something broken.

        Both halves are load bearing. The classname keeps the tolerance to the
        one file, and the KIND keeps it to a guard that ran and asserted: an
        `error` in that file is a guard that blew up, whose verdict about the
        record was never taken, and a file that failed to import contributed no
        timings at all, so recording past it would drop it from the record while
        reporting a successful write.
        """
        return self.kind == "failure" and self.classname == OWN_GUARD_CLASSNAME


def failed_cases(report: Path) -> list[FailedCase]:
    """Every test the junit report says went red.

    An unreadable report is a refusal rather than an empty list. It is reached
    only when the suite already exited non-zero, and at that moment "no failures
    found" and "could not tell" are the same sentence with opposite meanings
    (L98).
    """
    try:
        root = ElementTree.parse(report).getroot()
    except FileNotFoundError:
        raise SystemExit(
            f"the suite exited non-zero and wrote no report at {report}, so "
            "which tests failed cannot be established. Nothing was "
            "written.") from None
    except ElementTree.ParseError as broken:
        raise SystemExit(
            f"the run's report at {report} is not readable XML ({broken}), so "
            "which tests failed cannot be established. Nothing was "
            "written.") from None

    cases = []
    for case in root.iter("testcase"):
        for detail in case:
            if detail.tag in ("failure", "error"):
                cases.append(FailedCase(detail.tag,
                                        case.get("classname", ""),
                                        case.get("name", "")))
                break
    return cases


def blocking_failures(report: Path) -> list[str]:
    """The failures a measurement may not be taken past, named for a person."""
    return [case.identity for case in failed_cases(report)
            if not case.is_the_records_own_guard]


def measure(argv: list[str] | None = None,
            paths: list[str] | None = None) -> dict[str, float]:
    """Run the suite and sum every phase's duration per test file.

    The externals are REQUIRED rather than hoped for. Without ffmpeg and the
    macOS faces the expensive files skip, and a skipped file measures as free,
    which would quietly record the whole reference-frame set as cheap and take
    every one of them out of the slow set (L98).
    """
    environment = dict(os.environ,
                       POSTROLL_REQUIRE_FFMPEG="1",
                       POSTROLL_REQUIRE_GOLDENS="1")
    # --durations-min=0 as well as --durations=0: the count alone still hides
    # anything under 5ms, so without it a file made entirely of quick tests is
    # absent from the record, and absent has to mean "not measured" rather than
    # "measured as nothing" for the guards reading it to stay honest (L11).
    with tempfile.TemporaryDirectory() as workspace:
        # Asked for structurally rather than read back out of the terminal
        # output, because the decision below turns on WHICH tests failed and a
        # regex over pytest's prose answers "none" for a report it cannot parse
        # as readily as for a run that had none.
        report = Path(workspace) / "report.xml"
        command = ([sys.executable, "-m", "pytest"] + list(paths or ["tests/"])
                   + ["-q", "-n", "auto", "--durations=0", "--durations-min=0",
                      f"--junit-xml={report}"] + (argv or []))
        finished = subprocess.run(command, cwd=REPO_ROOT, env=environment,
                                  capture_output=True, text=True)

        totals: Counter[str] = Counter()
        for line in finished.stdout.splitlines():
            match = DURATION_LINE.match(line)
            if match:
                totals[Path(match.group(2)).name] += float(match.group(1))

        if finished.returncode != 0:
            # A red suite is generally not a measurement. The files that failed
            # did not run to completion, so their cost is whatever they got
            # through, and recording that would set a threshold from a broken
            # run. The single exception is a guard ABOUT this record reporting
            # that the record has drifted, which is the state this tool is
            # reached in and says nothing about anyone's timings (#837).
            cases = failed_cases(report)
            blocking = [case.identity for case in cases
                        if not case.is_the_records_own_guard]

            if not cases:
                raise SystemExit(
                    f"the suite exited {finished.returncode} and its report "
                    "names no failing test, so this is not a run that merely "
                    "had red tests: a usage error, an internal error or a run "
                    "that collected nothing all land here. Nothing was "
                    "written.\n"
                    + "\n".join(finished.stdout.splitlines()[-25:]))
            if blocking:
                raise SystemExit(
                    f"the suite exited {finished.returncode}, so these timings "
                    "are of a run that did not finish. Nothing was written.\n"
                    "These failures are not about the record itself:\n  "
                    + "\n  ".join(blocking))

            # Never silently: a tolerated failure is still one somebody has to
            # look at, and a tool that swallowed it would read exactly like one
            # that ran against a green suite (L11).
            print(f"recorded past {len(cases)} failing guard(s) about the "
                  f"record itself, which is what re-recording is for:")
            for case in cases:
                print(f"  {case.identity}")

    if not totals:
        raise SystemExit(
            "no per-file durations were found in pytest's output, so this "
            "measured nothing. Either --durations=0 stopped printing them or "
            "the line format changed; either way an empty record would report "
            "every file as free.")
    return dict(totals)


def main(argv: list[str] | None = None) -> int:
    words = list(sys.argv[1:] if argv is None else argv)

    if "--add" in words:
        return _add(words[words.index("--add") + 1:])

    stamped_at = datetime.now(timezone.utc).strftime("full-%Y-%m-%dT%H:%MZ")
    totals = measure(words)
    _write({"seconds": dict(sorted(totals.items())),
            "measured": Provenance.full(stamped_at, totals)})

    print(f"recorded {len(totals)} test files into "
          f"{RECORD.relative_to(REPO_ROOT)}, all from {stamped_at}")
    for name, seconds in sorted(totals.items(), key=lambda kv: -kv[1])[:10]:
        print(f"  {seconds:8.1f}s  {name}")
    return 0


def _add(paths: list[str]) -> int:
    """Measure new files beside the references, and merge them in (#1038).

    The whole point is NOT re-reading the suite. A full re-record re-derives
    every share from a run whose load has nothing to do with the tests, which is
    what moved a file across the expensive floor and turned a guard red on a
    suite nobody had changed.
    """
    if not paths:
        raise SystemExit(
            "--add needs the test files to add. Nothing was written.")

    record = json.loads(RECORD.read_text(encoding="utf-8"))
    stamped_at = datetime.now(timezone.utc).strftime("partial-%Y-%m-%dT%H:%MZ")
    print(f"measuring {len(paths)} file(s) beside "
          f"{len(REFERENCE_FILES)} reference files already in the record")

    totals = measure(paths=list(paths) + list(REFERENCE_FILES))
    grown = added(record, totals, run=stamped_at)
    _write(grown)

    for path in paths:
        name = Path(path).name
        entry = grown["measured"].get(name)
        if entry is None:
            print(f"  {name}: already in the record, left alone")
            continue
        print(f"  {name}: {grown['seconds'][name]}s "
              f"(measured {totals.get(name, 0):.3f}s, scaled {entry['scale']}x)")
    return 0


def _write(record: dict) -> None:
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    RECORD.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
