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

#: How many of the dearest files the fast local loop may skip (#1196).
#:
#: A COUNT, not a share, and that is the second correction this number has had.
#:
#: It was a share of the whole recorded run, chosen to sit in a gap so that no
#: small change in cost could carry a file across it. The reading is summed
#: per-test WALL time under `-n auto`, so it moves with contention, and a share
#: moves for two reasons: the file's own cost, and everything else's. The suite
#: growing therefore re-aimed the threshold on every unrelated branch.
#:
#: `test_generate_media_friday_clips` decided where that threshold sat NINE
#: times: 5.0%, 5.8%, 4.5%, 4.99%, 6.18%, 4.37%, and then 5.97%, 5.17% and
#: 5.96% in three recordings within a few hours of each other on 2026-09-01,
#: with nothing about the file changing. Each move cost a re-record, a marker
#: edit and a README count on a branch that had nothing to do with it, and by
#: the third the only placement that satisfied the old band sat in a window
#: 0.3% wide, which the next recording would have broken.
#:
#: The RANK is stable where the share is not. Measured across the eight
#: recorded versions of the duration record: ranks 3 and 4 have swapped
#: repeatedly, ranks 6 and 7 have swapped, and the file at rank 5 has been the
#: same file in every single one. So membership of the skipped set is decided
#: by order, which changes only when two files really do swap, rather than by a
#: line that moves under everything.
#:
#: Five, which is the set the share threshold produced whenever it happened to
#: land above that file. Those five are 918s of a roughly 1,400s run, and the
#: sixth is 64s, so this is where the saving is.
#:
#: `test_fast_subset_stays_honest.py` holds the boundary open: the fifth file
#: has to stay clearly dearer than the sixth, or two files a hair apart would
#: swap on ordinary noise and the fast run's contents would change with nobody
#: choosing it.
EXPENSIVE_COUNT = 5

#: How much dearer the last skipped file has to be than the first kept one.
#:
#: 1.35x, which is what that boundary measures today. Deliberately not derived
#: from the run to run noise the way the old band was: this is not a threshold
#: anything sits near, it is a question about two specific files swapping
#: places, and the eight recordings say that pair has never swapped.
#:
#: Ranks 6 and 7 HAVE swapped at 1.45x, which looks like a counterexample and
#: is not: those two are 44s and 64s, so a few seconds of contention reorders
#: them, while 86s against 64s is a real difference in what the files do.
MINIMUM_SEPARATION = 1.35


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
    """Files the fast local run is allowed to skip: the dearest few (#1196).

    By ORDER rather than by a threshold, because the order is what has held
    still. A share of the whole run moves when anything else in the suite does,
    and it re-aimed the old threshold on nine separate occasions.
    """
    ordered = sorted(recorded().items(), key=lambda pair: -pair[1])
    return {name for name, _ in ordered[:EXPENSIVE_COUNT]}


def unmeasured() -> set[str]:
    """Test files on disk that the record has never seen.

    The other direction of the comparison `files_on_disk()` was already used
    for. A record naming a file that has gone is caught by
    `test_fast_subset_stays_honest.py`; a file the record has never seen was
    simply absent, and absent is read as cheap by everything downstream.

    That is the safe direction for the fast run, which pays for a file it might
    have skipped. It is not safe for the reasoning: `EXPENSIVE_COUNT` and the
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
    costly = expensive()
    ordinary = [s for name, s in shares().items() if name not in costly]
    if not ordinary:
        raise AssertionError(
            "every recorded file is at or above the floor, so there is no "
            "ordinary file to size an unmeasured one against. The record or "
            f"{EXPENSIVE_COUNT} is wrong.")
    return len(unmeasured()) * max(ordinary)


def smallest_expensive_share() -> float:
    """The share of the cheapest file the fast run is allowed to skip.

    The scale the worst case above is judged against: unmeasured files that
    could add up to this are enough to change the picture the floor was chosen
    from.
    """
    over = [s for name, s in shares().items() if name in expensive()]
    if not over:
        raise AssertionError(
            f"the record names no expensive file at all, so "
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
