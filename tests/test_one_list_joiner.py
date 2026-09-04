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
#:
#: The connector is part of the shape, and that is the half this used to be
#: missing. `SentenceList` holds a rule about ENGLISH: a comma before "and",
#: and "and" alone at two items. A joiner that appends its last item after a
#: symbol is building a LABEL, "Story + Collage", and putting it on the shared
#: joiner would replace the plus with "and" and change what a button says.
#:
#: That was exempted by FILE NAME, with a comment claiming the exemption was
#: the reason rather than the name, which it was not: a second label joiner
#: anywhere else fired, and a genuine sentence joiner added to the same file
#: would have been waved through (#1165, L362, L562). The reason is derivable,
#: so it is derived.
BY_HAND = re.compile(
    r"dropLast\(\)\s*\.?\s*joined\(separator: \", \"\)"
    r"(?s:.{0,160}?)\b(?:and|or)\b")


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


#: A file whose joiner is deliberately NOT this rule, and why (L233).
#:
#: Empty, and that is the current truth rather than a placeholder. The one entry
#: it used to hold, `GenerationRunPlan.swift`, is now covered by the matcher
#: itself: that joiner appends its last item after a plus, so it is a label and
#: not a sentence, and `BY_HAND` no longer matches it.
#:
#: The entry is gone rather than kept because it was the defect #1165 is about.
#: It named ONE case while the comment beside it claimed to name the reason, so
#: a second label joiner written anywhere else fired, and a real sentence joiner
#: added to that same file would have been waved through by a whole-file skip
#: (L362, L135).
#:
#: A file added here now has to carry a reason no predicate can express.
NOT_A_SENTENCE: dict[str, str] = {}


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


def test_every_exemption_still_names_a_file_that_joins_by_hand():
    """A stale exemption excuses a real failure silently, which is the one way
    an exemption list can be worse than no list at all (L233, L217).

    One assertion rather than one per entry, so the EMPTY case is a pass. As a
    parametrised test it reported "got empty parameter set" and pytest printed
    it as a skip, which is indistinguishable from a check that stopped running
    (L98)."""
    stale = []
    for path, why in sorted(NOT_A_SENTENCE.items()):
        source = REPO_ROOT / path
        if not source.is_file():
            stale.append(f"{path} is gone, so this excuses nothing")
        elif not BY_HAND.search(_code(source)):
            stale.append(f"{path} no longer joins a list by hand. Its reason "
                         f"was: {why}")

    assert not stale, (
        "these exemptions name no file that still joins a list by hand, so "
        "each would quietly excuse it if it started again:\n" + "\n".join(stale))


def test_the_matcher_tells_a_sentence_from_a_label():
    """Both directions, and this is the pair the exemption used to stand in for.

    A matcher that fired on both would send somebody to replace a plus with an
    "and" and change what a button says; one that fired on neither would pass
    an eleventh hand written sentence joiner (L159)."""
    sentence = ('let head = names.dropLast().joined(separator: ", ")\n'
                'return "\\(head) and \\(names.last!)"')
    label = ('let head = names.dropLast().joined(separator: ", ")\n'
             'return "\\(head) + \\(names.last!)"')

    assert BY_HAND.search(sentence), (
        "the matcher no longer sees the shape all ten of #933's joiners had, "
        "so this whole file guards nothing")
    assert not BY_HAND.search(label), (
        "a joiner that appends its last item after a symbol is building a "
        "label (Story + Collage), not an English sentence, and SentenceList "
        "would replace the plus with an and")


def test_the_label_joiner_is_still_the_shape_that_exempts_it():
    """The exemption above is now DERIVED, so it is only correct while the code
    it covers still has the property it is derived from. If GenerationRunPlan
    starts joining with an "and" it is a sentence and belongs on the shared
    rule, and this says so rather than letting the sweep pass in silence
    (L217)."""
    plan = _code(SOURCES / "Services" / "GenerationRunPlan.swift")

    assert "dropLast()" in plan, (
        "GenerationRunPlan no longer joins a list at all, so the reasoning "
        "that made it exempt no longer describes anything here")
    assert not BY_HAND.search(plan), (
        "GenerationRunPlan now joins with a sentence connector, so it is "
        "writing English and belongs on SentenceList like the other ten")
