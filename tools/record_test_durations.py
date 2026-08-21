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
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORD = REPO_ROOT / "tests" / "fixtures" / "test_file_durations.json"

#: Every phase, not just `call`. A file whose cost is in an expensive fixture is
#: exactly as slow to run, and counting only the call would report it as cheap.
DURATION_LINE = re.compile(
    r"^\s*([\d.]+)s (?:call|setup|teardown)\s+(tests/test_[a-z0-9_]+\.py)::")


def measure(argv: list[str] | None = None) -> dict[str, float]:
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
    command = [sys.executable, "-m", "pytest", "tests/", "-q", "-n", "auto",
               "--durations=0", "--durations-min=0"] + (argv or [])
    finished = subprocess.run(command, cwd=REPO_ROOT, env=environment,
                              capture_output=True, text=True)

    totals: Counter[str] = Counter()
    for line in finished.stdout.splitlines():
        match = DURATION_LINE.match(line)
        if match:
            totals[Path(match.group(2)).name] += float(match.group(1))

    if finished.returncode != 0:
        # A red suite is not a measurement. The files that failed did not run to
        # completion, so their cost is whatever they got through, and recording
        # that would set a threshold from a broken run.
        raise SystemExit(
            f"the suite exited {finished.returncode}, so these timings are of a "
            f"run that did not finish. Nothing was written.\n"
            + "\n".join(finished.stdout.splitlines()[-25:]))
    if not totals:
        raise SystemExit(
            "no per-file durations were found in pytest's output, so this "
            "measured nothing. Either --durations=0 stopped printing them or "
            "the line format changed; either way an empty record would report "
            "every file as free.")
    return dict(totals)


def main() -> int:
    totals = measure(sys.argv[1:])
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    RECORD.write_text(
        json.dumps({"seconds": dict(sorted(totals.items()))}, indent=2) + "\n",
        encoding="utf-8")

    print(f"recorded {len(totals)} test files into "
          f"{RECORD.relative_to(REPO_ROOT)}")
    for name, seconds in sorted(totals.items(), key=lambda kv: -kv[1])[:10]:
        print(f"  {seconds:8.1f}s  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
