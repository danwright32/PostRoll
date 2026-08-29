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
#: The floor is chosen from where the distribution actually is, not picked round
#: (L172), and it has now been re-chosen three times: for #810, for #826, and
#: for #840. Sorted by share the suite reads, measured on 2026-08-22:
#:
#:     test_golden_frames.py                    18.3%
#:     test_closing_crossfade_legibility.py     14.9%
#:     test_thursday_reel_legibility.py         12.8%
#:     test_frame_legibility.py                  9.1%
#:     test_slider_program_plate.py              4.7%
#:     test_generate_media_friday_clips.py       4.5%
#:     test_record_design_fingerprints.py        4.0%
#:     test_render_clip_reel.py                  3.7%
#:     test_phone_safe_area.py                   3.4%
#:     test_record_codec_change.py               2.6%    and a tail of 148 more
#:
#: so the only gap left is between 9.1% and 4.7%, and 6.5% is near its geometric
#: middle: 1.38x of clear air below and 1.40x above. Every candidate lower down
#: is inside the run of files from 4.7% to 2.6%, where each step is under 1.2x
#: and no floor could be placed without something sitting on it.
#:
#: What moved. Nothing about these files changed for #840; the record was
#: re-taken because two new test files made it stop covering the suite, and a
#: re-take measures every file again. Four files that were within 1.2x of the
#: old 3.7% floor came out on the other side of it, which is precisely the drift
#: the gap rule exists to notice rather than absorb.
#:
#: The cost of moving the floor up, said plainly: the fast local run now pays
#: for `test_generate_media_friday_clips.py`, about 4.5% of the run, which it
#: used to skip. That file has been on the line every time this was re-chosen
#: (5.05% and 5.76% in two readings against a 5.4% floor for #826, 4.5% now),
#: and a marker that flips with the noise is worse than either answer.
#:
#: It was 8% before #810, 5.4% after it, 3.7% after #826, and 6.5% after #840.
#: Each time the shape of the run changed, not the rule.
#:
#: 7.5% on 2026-08-23, re-chosen for the same reason as every entry above it and
#: with the same file on the line. Two new test files for #866 made the record
#: stop covering the suite, so it was re-taken, and a re-take measures every
#: file again. `test_generate_media_friday_clips.py` came out at 5.4% against
#: 4.5%, which put it inside the 5.2% to 8.1% band the old floor asked to be
#: clear, and the guard said so.
#:
#: The gap it now sits in is 5.4% below (that same file) and 10.5% above
#: (`test_frame_legibility.py`), a factor of 1.94, and 7.5% was its geometric
#: middle.
#:
#: 7% since 2026-08-28, re-chosen against a third recording. This floor moves
#: whenever the suite grows enough to change what share a file is, which is the
#: guard working rather than churn: it goes red the moment a file lands near the
#: line, and the answer is always to re-measure and re-choose rather than to
#: widen the band.
#:
#: `test_generate_media_friday_clips` was 6.1% and is 4.99% now, not because it
#: got faster but because the suite around it grew. It falls back OUT of the
#: expensive set, so the fast run pays for it again, and the set is four files
#: as it was before 2026-08-27.
#:
#: The widest gap in the distribution is now 4.99%
#: (`test_generate_media_friday_clips`) to 9.67% (`test_frame_legibility`), a
#: factor of 1.94, and 7% is its geometric middle. Its neighbours sit at 0.71x
#: and 1.38x of it against a band of 0.8 to 1.25.
#:
#: 4.6% since 2026-08-29, re-chosen against a fourth recording. That recording
#: was forced by #932 adding a test file, and it moved the distribution enough
#: that the 7% floor no longer sat in clear air: `test_generate_media_friday_clips`
#: came out at 6.18%, inside the 5.6% to 8.8% band the old floor asked to be
#: clear, and the guard said so. This is the fourth time that same file has
#: decided where the floor goes, which is what a file sitting near the knee of a
#: distribution does.
#:
#: The widest gap in the distribution is now 3.45%
#: (`test_render_clip_reel`) to 6.18% (`test_generate_media_friday_clips`), a
#: factor of 1.79, and 4.62% is its geometric middle. The band a floor there
#: asks to be clear is 3.70% to 5.77%, and its neighbours sit at 0.75x and 1.34x
#: of it against a band of 0.8 to 1.25.
#:
#: The gap above it, 6.18% to 9.74%, is 1.58x. A band needing 1.5625x of clear
#: air fits inside that by four hundredths of a percentage point on each side,
#: which is not clear air, it is a coincidence of rounding: a floor placed there
#: would go red on the next reading's noise. So the wider gap is the one taken,
#: as it has been every time.
#:
#: `test_generate_media_friday_clips` therefore moves back INTO the expensive
#: set and the fast run stops paying for it, as it did before 2026-08-28. The
#: set is five files. Nothing about that file changed; the suite around it did.
#:
#: `test_fast_subset_stays_honest.py` holds the gap open: a file measured close
#: to this turns it red and asks for the floor to be re-chosen against the
#: distribution as it is then, rather than letting it silently drift into the
#: dense part where a small change moves several files at once.
EXPENSIVE_SHARE = 0.046

#: How much clear air the floor needs either side of it, as a multiplier.
#:
#: 0.8 to 1.25 of the floor, so no file may sit between 6.0% and 9.4% of the run.
#: The real margins on the record as it stands are 5.4% below and 10.5% above.
#:
#: Deliberately left alone when the floor moved to 7.5% on 2026-08-23. The band
#: says how much noise a reading carries and the floor says where the gap is;
#: widening the band to absorb a file that has moved would answer a measurement
#: with a looser rule, which is the one response this guard exists to prevent.
#:
#: These were 0.6 and 1.6, chosen when the gap was a factor of 3.5. That band
#: asks for 2.67x of clear air and this gap is 1.84x, so no placement in it
#: could satisfy the old numbers: keeping them would leave the guard permanently
#: red, or push the floor above a file that really does cost 5% of the run.
#:
#: So they are re-derived from what they exist to tolerate, which is how much a
#: share moves between two readings of the SAME tree. Measured on this Mac on
#: 2026-08-22, over the files at or above 2% of the run, the worst swing was
#: 1.19x (test_frame_legibility and test_thursday_reel_legibility), and the file
#: this floor sits beside swung 1.14x. A 1.25x band clears the noise this suite
#: really has. It is a loosening, said plainly, and it is a loosening onto a
#: measurement rather than onto a round number.
GAP_BELOW, GAP_ABOVE = 0.8, 1.25


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


def unmeasured() -> set[str]:
    """Test files on disk that the record has never seen.

    The other direction of the comparison `files_on_disk()` was already used
    for. A record naming a file that has gone is caught by
    `test_fast_subset_stays_honest.py`; a file the record has never seen was
    simply absent, and absent is read as cheap by everything downstream.

    That is the safe direction for the fast run, which pays for a file it might
    have skipped. It is not safe for the reasoning: `EXPENSIVE_SHARE` and the
    gap it sits in are computed over the RECORDED files alone, so a record
    covering half the suite reports a healthy gap while describing a suite that
    no longer exists, and reads green for the same reason it always did.
    """
    return files_on_disk() - set(recorded())


def worst_case_unmeasured_share() -> float:
    """How much of the run the unmeasured files could account for.

    Their real cost is exactly what nobody has measured, so this stands each of
    them at the largest ORDINARY file in the record: the biggest a file can be
    while the fast run still pays for it. That is a plausible worst case rather
    than a true bound, since a new file can be heavier than any existing one,
    and it is stated here rather than hidden so the number can be argued with.

    Derived from the record instead of typed in, so it follows the suite. On the
    record as it stands the largest ordinary file is 3.0% and the smallest
    expensive one 17.5%, so five unmeasured files could between them be as much
    of the run as the smallest file the fast run skips. Those are printed by the
    check that reads this, so the failure carries the live numbers rather than
    these (L210).
    """
    ordinary = [s for s in shares().values() if s < EXPENSIVE_SHARE]
    if not ordinary:
        raise AssertionError(
            "every recorded file is at or above the floor, so there is no "
            "ordinary file to size an unmeasured one against. The record or "
            f"{EXPENSIVE_SHARE:.0%} is wrong.")
    return len(unmeasured()) * max(ordinary)


def smallest_expensive_share() -> float:
    """The share of the cheapest file the fast run is allowed to skip.

    The scale the worst case above is judged against: unmeasured files that
    could add up to this are enough to change the picture the floor was chosen
    from.
    """
    over = [s for s in shares().values() if s >= EXPENSIVE_SHARE]
    if not over:
        raise AssertionError(
            f"no recorded file reaches {EXPENSIVE_SHARE:.0%} of the run, so "
            "there is nothing for the fast run to skip and nothing here to "
            "measure an unmeasured file against.")
    return min(over)


def files_on_disk() -> set[str]:
    """Every test file there is, so the record can be held to the suite."""
    found = {path.name for path in TESTS_DIR.glob("test_*.py")}
    if len(found) < 50:
        raise AssertionError(
            f"only {len(found)} test files were found in {TESTS_DIR}, which is "
            "not this suite. A scan that had stopped matching would make every "
            "comparison against it pass over almost nothing.")
    return found
