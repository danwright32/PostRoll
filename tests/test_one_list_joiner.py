"""#933: ten hand written list joiners that disagreed with each other.

`PhotoTagSheetNote`, `DuplicateHandleMark`, `BackgroundWork` and
`DayRebuildRefusal` wrote "a, b and c". `MissingMediaScan`, `DesignStamp`,
`DesignStaleScan`, `RecurringAccounts`, `ExportReadiness` and
`GenerationFailureText` wrote "a, b, and c". Two sentences on one screen could
punctuate the same list differently.

Dan settled the convention on 2026-08-28: the comma before "and" stays, and it
appears only from three items, so two are joined by "and" alone. `SentenceList`
holds that rule, and #919 used it for one new note rather than adding an
eleventh copy. All ten now come here.

## Why a sweep rather than trusting the migration

Sharing a rule's DATA while copying the code that APPLIES it is not
consolidation: the shared constant reads as the single source of truth, so
nobody asks whether the logic beside it was duplicated, and a change to how the
data is applied lands in one copy only (L370). The joiner is logic, so the check
has to be that nobody writes it again.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from source_text import swift_without_comments

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "PostRollApp" / "Sources"
HOME = SOURCES / "Models" / "SentenceList.swift"

#: What a hand written joiner looks like in this codebase.
#:
#: All ten were this shape: everything but the last joined with ", ", then the
#: last appended after an "and". Matched on the CONSTRUCTION rather than on a
#: list of file names, so the eleventh is caught wherever somebody writes it
#: (L96, L247).
BY_HAND = re.compile(r"dropLast\(\)\s*\.?\s*joined\(separator: \", \"\)")


def _code(path: Path) -> str:
    """One file with its comments blanked (#1074).

    The doc comment on `SentenceList` NAMES the ten files it replaced, and each
    migrated file explains what it used to do, so a raw scan is answered by
    prose describing the very thing that was removed (L103).
    """
    return swift_without_comments(path.read_text(encoding="utf-8"))


def swift_files() -> list[Path]:
    found = sorted(SOURCES.rglob("*.swift"))
    assert len(found) > 100, (
        f"only {len(found)} Swift files found under {SOURCES}, which is not "
        f"this app: the sweep below would pass by looking at almost nothing")
    return found


#: A joiner that is deliberately NOT this rule, and why (L233).
#:
#: `GenerationRunPlan.joined` builds a LABEL, "Story + Collage", not an English
#: sentence, so putting it on `SentenceList` would replace the plus with "and"
#: and change what the button says. The exemption is the reason rather than the
#: name, so a second label joiner is covered without an edit.
NOT_A_SENTENCE = {
    "PostRollApp/Sources/Services/GenerationRunPlan.swift":
        "joins with a plus to build a label (Story + Collage), not a sentence",
}


def test_nothing_but_the_shared_joiner_writes_one():
    offenders = []
    for path in swift_files():
        if path == HOME:
            continue
        # Comments blanked: the doc comment on `SentenceList` NAMES the ten
        # files it replaced, and a raw scan is answered by prose describing the
        # thing that was removed (L103, #1074).
        relative = str(path.relative_to(REPO_ROOT))
        if relative in NOT_A_SENTENCE:
            continue
        if BY_HAND.search(_code(path)):
            offenders.append(relative)

    assert not offenders, (
        "these write a list joiner by hand instead of using SentenceList, so "
        "they can punctuate a list differently from every other sentence on the "
        "same screen, which is what #933 was: " + ", ".join(offenders))


def test_the_shared_joiner_is_where_the_sweep_says_it_is():
    """The positive control. If `SentenceList` moved or lost its joiner, the
    sweep above would pass by there being nothing to find anywhere (L98)."""
    assert HOME.is_file(), f"{HOME} is gone, so the sweep is exempting a file "\
                           f"that no longer holds the rule"
    assert BY_HAND.search(_code(HOME)), (
        "SentenceList no longer joins a list, so the exemption above excuses "
        "nothing and every other file could be doing it by hand")


@pytest.mark.parametrize("file", [
    "Models/BackgroundWork.swift",
    "Models/PhotoTagSheetNote.swift",
    "Services/DuplicateHandleMark.swift",
    "Services/MissingMediaScan.swift",
    "Services/DayRebuildRefusal.swift",
    "Services/GenerationFailureText.swift",
    "Services/DesignStaleScan.swift",
    "Services/RecurringAccounts.swift",
    "Services/DesignStamp.swift",
    "Services/ExportReadiness.swift",
])
def test_each_of_the_ten_now_asks_the_shared_one(file: str):
    """The other direction, and the one the sweep alone cannot give.

    "Nobody writes a joiner by hand" is satisfied by a file that stopped
    listing anything at all (L283). Each of the ten has to be reaching the
    shared rule, by name.
    """
    code = _code(SOURCES / file)

    assert "SentenceList." in code, (
        f"{file} no longer asks SentenceList, so either it stopped naming a "
        f"list or it went back to punctuating one its own way")


@pytest.mark.parametrize("path,why", sorted(NOT_A_SENTENCE.items()))
def test_every_exemption_still_names_a_file_that_joins_by_hand(path: str, why: str):
    """A stale exemption excuses a real failure silently, which is the one way
    an exemption list can be worse than no list at all (L233, L217)."""
    source = REPO_ROOT / path

    assert source.is_file(), f"{path} is gone, so this exemption excuses nothing"
    assert BY_HAND.search(_code(source)), (
        f"{path} no longer joins a list by hand, so the exemption is stale and "
        f"would quietly excuse it if it started again. Its reason was: {why}")
