"""What each test file costs, read from the measurement rather than guessed (#766).

`pytest.mark.slow` decides what `make test-python-fast` skips. The set carrying
it used to be derived from `swift.yml`'s reference-frame matrix, which is the set
of files needing macOS system fonts, on the premise that the matrix is "where the
time goes".

Two different properties were being named by one marker. A file is FONT
DEPENDENT, meaning it must run where SignPainter and HelveticaNeue are, or it is
EXPENSIVE, meaning the fast loop may skip it. A file can be either without being
both, and `tests/test_phone_safe_area.py` landed in exactly that position in
#760: marked slow purely so the fast-subset guard was satisfied. One word naming
two units reads correctly in each file and contradicts itself across them (L118).

Measured on 2026-08-21, the premise turned out to be wrong in both directions:
`test_generate_media_friday_clips.py` is 3.3% of the run and is in no shard, so
the fast run paid for it every time, while `test_story_title_clamp.py` is 0.5%
and was skipped because it needs the faces.

So the expensive set is derived from `tools/record_test_durations.py`'s record
instead, which measures the thing the marker claims. Font dependence keeps its
own derivation, off the marker in the file, in
`tests/test_ci_runs_the_font_dependent_checks.py`.

Every function here RAISES rather than returning an empty answer, for the reason
`ci_workflow.py` gives: "the record is not there" and "there is nothing
expensive" have to be different outcomes, or a missing file reports a suite in
which nothing is slow (L98).
"""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
RECORD = REPO_ROOT / "tests" / "fixtures" / "test_file_durations.json"

#: What SHARE of the whole run a file has to be before the fast loop may skip it.
#:
#: A share rather than a number of seconds, and that is a correction rather than
#: a preference (#766). What `tools/record_test_durations.py` reads out of pytest
#: is summed per-test WALL time under `-n auto`, not CPU, so it moves with how
#: much contention there was. Measured on this Mac on 2026-08-21, the same suite
#: on the same machine an hour apart:
#:
#:     test_frame_legibility.py      206.9s then 334.8s    26.9% then 31.7%
#:     test_golden_frames.py         145.8s then 223.7s    18.9% then 21.2%
#:     test_slider_program_plate.py   25.7s then  37.3s     3.3% then  3.5%
#:
#: The seconds moved by 60%, because the second run was under `--dist worksteal`
#: and therefore kept more cores busy at once (#783). The shares barely moved at
#: all. A floor in seconds would have been crossed by four files without one line
#: of test code changing.
#:
#: 8% is chosen from where the distribution actually is, not picked round (L172).
#: Sorted by share the suite has a gap of nearly 5x in it: three files at 31.7%,
#: 21.2% and 17.3%, then nothing until 3.5%, then a long tail of 140 files under
#: that. 8% sits in the gap with more than a factor of two of clear air either
#: side, and both readings agree about it.
#:
#: `test_fast_subset_stays_honest.py` holds the gap open: a file measured close
#: to this turns it red and asks for the floor to be re-chosen against the
#: distribution as it is then, rather than letting it silently drift into the
#: dense part where a small change moves several files at once.
EXPENSIVE_SHARE = 0.08

#: How much clear air the floor needs either side of it, as a multiplier.
#:
#: 0.6 to 1.6 of the floor, so no file may sit between 4.8% and 12.8% of the run.
#: The real margins today are 3.5% below and 17.3% above.
GAP_BELOW, GAP_ABOVE = 0.6, 1.6


def recorded() -> dict[str, float]:
    """Every measured file and its summed seconds.

    Raises rather than returning nothing, because a record that has gone missing
    would otherwise report a suite in which no file is expensive, which is
    indistinguishable from one where the marker is correctly absent everywhere.
    """
    if not RECORD.exists():
        raise AssertionError(
            f"{RECORD.relative_to(REPO_ROOT)} is missing, so nothing can say "
            "which test files are expensive. Record it with "
            "`venv/bin/python tools/record_test_durations.py`.")
    seconds = json.loads(RECORD.read_text(encoding="utf-8")).get("seconds")
    if not seconds:
        raise AssertionError(
            f"{RECORD.relative_to(REPO_ROOT)} records no files at all, so every "
            "check derived from it is measuring an empty set.")
    return {name: float(value) for name, value in seconds.items()}


def shares() -> dict[str, float]:
    """Each measured file as a fraction of the whole recorded run.

    Derived here rather than stored, so the record keeps the raw reading it was
    taken from and this stays re-derivable. A file of shares alone could not be
    argued with: a run measured under contention and a file that really is that
    large produce the same fraction, and only the seconds tell them apart.
    """
    seconds = recorded()
    total = sum(seconds.values())
    if total <= 0:
        raise AssertionError(
            f"{RECORD.relative_to(REPO_ROOT)} sums to {total}s, so every share "
            "derived from it is meaningless")
    return {name: value / total for name, value in seconds.items()}


def expensive() -> set[str]:
    """Files the fast local run is allowed to skip."""
    return {name for name, share in shares().items() if share >= EXPENSIVE_SHARE}


def files_on_disk() -> set[str]:
    """Every test file there is, so the record can be held to the suite."""
    found = {path.name for path in TESTS_DIR.glob("test_*.py")}
    if len(found) < 50:
        raise AssertionError(
            f"only {len(found)} test files were found in {TESTS_DIR}, which is "
            "not this suite. A scan that had stopped matching would make every "
            "comparison against it pass over almost nothing.")
    return found
