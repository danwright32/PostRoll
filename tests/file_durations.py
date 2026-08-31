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
import subprocess
from pathlib import Path, PurePosixPath
from typing import Iterable, Mapping

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
#: 4.6% earlier on 2026-08-29, re-chosen against a fourth recording, which had
#: `test_generate_media_friday_clips` at 6.18% and put it back IN the expensive
#: set as a fifth file.
#:
#: 7.1% since 2026-08-29, re-chosen against a fifth recording forced by #962
#: adding two test files. Adding any file makes the
#: record incomplete, and re-recording re-reads the WHOLE suite, so the floor is
#: re-chosen against the distribution as it then is rather than against the one
#: it was chosen from. This reading came in at 1737s against the previous 1071s,
#: the same suite on the same Mac under a different load, which is why the
#: shares moved without any test changing.
#:
#: `test_generate_media_friday_clips` came out at 4.37%, down from 6.18%, and
#: it is the fifth time that same file has decided where the floor goes, which
#: is what a file sitting near the knee of a distribution does.
#:
#: The widest gap in the distribution is now 4.37%
#: (`test_generate_media_friday_clips`) to 11.54% (`test_frame_legibility`), a
#: factor of 2.64, and 7.10% is its geometric middle. The band a floor there
#: asks to be clear is 5.68% to 8.88%, and its neighbours sit at 0.62x and
#: 1.63x of it against a band of 0.8 to 1.25, so it has more clear air either
#: side than any floor placed here has had.
#:
#: `test_generate_media_friday_clips` therefore moves back OUT of the expensive
#: set and the fast run pays for it again, as it did before 2026-08-29. The set
#: is four files. Nothing about that file changed; the suite around it did, and
#: this is the second reading in two days to say so, so the next person to move
#: this number should suspect the READING rather than the file.
#:
#: `test_fast_subset_stays_honest.py` holds the gap open: a file measured close
#: to this turns it red and asks for the floor to be re-chosen against the
#: distribution as it is then, rather than letting it silently drift into the
#: dense part where a small change moves several files at once.
EXPENSIVE_SHARE = 0.071

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
            f"{_where(RECORD)} is missing, so nothing can say "
            "which test files are expensive. Record it with "
            "`venv/bin/python tools/record_test_durations.py`.")
    seconds = json.loads(RECORD.read_text(encoding="utf-8")).get("seconds")
    if not seconds:
        raise AssertionError(
            f"{_where(RECORD)} records no files at all, so every "
            "check derived from it is measuring an empty set.")
    return {name: float(value) for name, value in seconds.items()}


def _where(path: Path) -> str:
    """The record's path, named for a person, from wherever it is.

    `relative_to` RAISES when the path is outside the repository, which is what
    every test that points these readers at a fixture does. A refusal message
    that crashes while being built is worse than the refusal it was replacing
    (L10), and it hid a real one behind a ValueError the first time it happened.
    """
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def provenance() -> dict[str, dict]:
    """How each recorded reading was taken (#1038).

    The record used to be a bare map of file to seconds, and nothing in it said
    which RUN each number came from. A full re-record takes every reading in one
    run, so they are all comparable. A file added afterwards is a reading from a
    different run under different load, scaled onto the record's by measuring it
    beside references, and mixing the two SILENTLY is what #1038 was about
    (L224). Recording it does not stop the mixing; it stops it being invisible.
    """
    stamped = json.loads(RECORD.read_text(encoding="utf-8")).get("measured")
    if not stamped:
        raise AssertionError(
            f"{_where(RECORD)} records no provenance at all, so "
            "nothing says which run any of its readings came from and a record "
            "mixing several is indistinguishable from one taken in a single "
            "run (#1038). Re-record with `make record-test-durations`.")
    return stamped


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
            f"{_where(RECORD)} sums to {total}s, so every share "
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


# ── the branch that adds a test file is the one that measures it (#1058) ─────
#
# `worst_case_unmeasured_share` above bounds the ACCUMULATION, which is the
# right question for whether the floor's distribution still describes this
# suite. It is the wrong question for who pays: one or two new files sit under
# the bound and the debt lands on whoever later tips it over, for files they did
# not write.
#
# These answer the narrower question that has a clear owner. Both checks stay,
# because neither covers the other (L129): this one cannot see the backlog that
# landed before it existed, nor a file arriving by any route other than a commit
# on a branch, and the aggregate one cannot say whose change caused it.

#: What the record holds one entry per. `test_*.py` is what pytest collects, so
#: a helper module beside them (conftest.py, this file) has no duration of its
#: own and demanding one would be a rule nothing could satisfy.
_MEASURED_PREFIX = "test_"


def unmeasured_additions(added: Iterable[str],
                         recorded: Mapping[str, float]) -> list[str]:
    """The added paths that name a test file the record has never seen.

    Membership, never truthiness: a file recorded at 0.0 seconds has been
    measured, and several real guard files are, so reading a falsy value as
    unmeasured would demand they be re-measured forever with no value that ever
    satisfied it (L11).
    """
    named = []
    for path in added:
        parts = PurePosixPath(path)
        if parts.parent != PurePosixPath("tests"):
            continue
        if not (parts.name.startswith(_MEASURED_PREFIX)
                and parts.suffix == ".py"):
            continue
        if parts.name not in recorded:
            named.append(parts.name)
    return sorted(named)


def added_test_files(repo_root: Path, base: str = "origin/main",
                     ) -> tuple[str, ...] | None:
    """Paths this branch ADDS under tests/, against its branch point with `base`.

    `None` when that cannot be established, and never `()`. No git, no `base`
    ref, a shallow clone with no merge base: none of those is evidence that the
    branch added nothing, and answering with an empty tuple would report a clean
    branch for a question nobody managed to ask (L98, L119).

    Committed changes only. A file being written right now is not yet a claim
    about anything, and failing the suite the moment a new test file appears
    would fire in the middle of every piece of test-first work, which is when it
    is least useful and most likely to be worked around. Reading the merge base
    means it fires once the file is committed, still before the push.

    ADDED, not touched. `--diff-filter=A` is the whole point: editing an
    existing test file is not creating one, and reporting it would make every
    branch owe a measurement for work it did not create.
    """
    def git(*arguments: str) -> str | None:
        done = subprocess.run(["git", "-C", str(repo_root), *arguments],
                              capture_output=True, text=True, check=False)
        return done.stdout.strip() if done.returncode == 0 else None

    point = git("merge-base", base, "HEAD")
    if not point:
        return None
    listed = git("diff", "--name-only", "--diff-filter=A", point, "HEAD",
                 "--", "tests/")
    if listed is None:
        return None
    return tuple(line.strip() for line in listed.splitlines() if line.strip())
