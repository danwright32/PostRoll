"""Putting an @ in front of a stored value claims it IS an account (#1112).

`PythonBridge.isRealHandle` is the read time test for whether a stored value is
an account that can be tagged, credited, invited or linked: shaped like a
username AND not one of the sentinels the pipeline writes when a search found
nobody. The book deliberately KEEPS those sentinels, so that a name searched
for once is not searched for again, which is what makes the read time question
the one that matters.

It has been added to a surface at a time, by hand, and found the same way each
time: #899, #917, #926, #981, and #973 for the profile link. Ten call sites,
each one an issue. Nothing checked that the eleventh surface asks, so the
eleventh omission was going to be found the same slow way, and each one ships
junk somewhere different: a caption, Instagram's tag list, a collaborator
invite, a live profile link.

## What this reads

The moment a value becomes a claim rather than a string is the `@`. A
`"@\\(value)"` written anywhere in the app says "this is an account", and it is
the one shape shared by every one of those defects. So the sweep finds them,
and asks whether the declaration building the mention asked the shared
question.

Nearby, not merely somewhere in the file: a file-wide search is answered by any
other use of the check elsewhere in it (L178), and these files are thousands of
lines long. The window is the declaration the mention sits in, from the `func`
or `var` before it to the one after. A local `var` between the check and the
mention narrows that window and fails this guard, which is the safe direction.

## Comments are stripped, string literals are NOT

Every other Swift sweep here reads `swift_code_only`, which blanks comments AND
string contents so a guard cannot be satisfied or tripped by prose. The subject
here IS a string literal, so blanking its contents would blank the very thing
being read. Comments still go, which is what stops a comment quoting `"@\\(x)"`
from being counted as a mention.

## Exemptions are named with what answered for them

A mention whose value was already gated upstream does NOT get a second copy of
the question: two spellings of one rule are two things to keep in step, which
is the reason `AccountFetchDue` gives for not repeating it either. Those sites
are listed below with the gate that stands in front of them, so the reason is
recorded rather than left for the next reader to reconstruct (L129, L233).
"""

from __future__ import annotations

import re
from pathlib import Path

from tests.source_text import swift_files, swift_without_comments

REPO = Path(__file__).resolve().parent.parent
SOURCES = REPO / "PostRollApp" / "Sources"

# `"@\(` in Swift source: the start of a string literal that interpolates a
# value straight after an at sign.
MENTION = re.compile(r'"@\\\(')

# A declaration this guard treats as a scope boundary. Deliberately includes
# local `var`s: a narrower window can only make the guard stricter.
DECLARATION = re.compile(
    r"(?m)^[ \t]*(?:@\w+\s+)*"
    r"(?:private |fileprivate |internal |public |static |final |nonisolated |lazy |"
    r"@discardableResult\s*)*"
    r"(?:func|var)\s+(\w+)")

CHECK = "isRealHandle"

# (file, declaration) -> what already answered the question, so this mention is
# not a claim made on an unchecked value.
EXEMPT = {
    ("RecurringAccounts.swift", "list"):
        "the items come from `needingAttention`, whose accounts are "
        "`CaptionBlocks.accountsTagged`: the week's tag list, which only "
        "`TypedCredit.read` mentions reach, plus `EventHandleSuggestions."
        "accounts`, which asks. A second copy here would be a second thing to "
        "keep in step",
    ("InsightsOrgsView.swift", "body"):
        "the org on an insights row is an account Instagram itself reported "
        "against Dan's own posts, not a handle stored on a performer, so the "
        "stored-value question does not arise",
    ("InsightsPostsView.swift", "body"):
        "the same account from the same report, on the posts screen",
    ("InsightsOverviewView.swift", "body"):
        "`AudienceControlNotice` names the credited accounts an insight report "
        "carries, which come from the analytics store rather than from a "
        "performer record",
    ("OCRReviewView.swift", "body"):
        "a PLACEHOLDER built from the organisation and venue NAME, showing the "
        "shape of the value to type into an empty field. There is no stored "
        "value here to check, and refusing to draw the hint would leave the "
        "field with no example at all",
}

# Below this the sweep has stopped reading the app (L98, L320). Eleven today.
FEWEST_MENTIONS = 11


def declarations(text: str) -> list[tuple[int, str]]:
    return [(m.start(), m.group(1)) for m in DECLARATION.finditer(text)]


def scope(text: str, at: int) -> tuple[str, str]:
    """The declaration `at` sits in: its name, and its text."""
    found = declarations(text)
    before = [d for d in found if d[0] <= at]
    after = [d for d in found if d[0] > at]
    start, name = before[-1] if before else (0, "(file)")
    end = after[0][0] if after else len(text)
    return name, text[start:end]


def unchecked_mentions(text: str) -> list[str]:
    """The declarations that build an @mention without asking the check."""
    named = []
    for found in MENTION.finditer(text):
        name, body = scope(text, found.start())
        if CHECK not in body:
            named.append(name)
    return named


def mention_count(text: str) -> int:
    return len(MENTION.findall(text))


# ── the reading, on text this file controls ─────────────────────────────────


def test_a_mention_built_with_no_check_is_named():
    assert unchecked_mentions(
        '    func label() -> String {\n'
        '        return "@\\(performer.handle)"\n'
        '    }\n') == ["label"]


def test_a_mention_built_after_the_check_is_not_named():
    assert unchecked_mentions(
        '    func label() -> String {\n'
        '        guard PythonBridge.isRealHandle(performer.handle) else { return "" }\n'
        '        return "@\\(performer.handle)"\n'
        '    }\n') == []


def test_a_check_in_a_different_declaration_does_not_answer_for_this_one():
    """The half of this that a file-wide search cannot do (L178). These files
    run to thousands of lines and every one of them asks the question
    somewhere."""
    assert unchecked_mentions(
        '    func gated() -> Bool { PythonBridge.isRealHandle(handle) }\n'
        '    func label() -> String { return "@\\(performer.handle)" }\n') == ["label"]


def test_a_mention_written_in_a_comment_is_not_a_mention():
    assert unchecked_mentions(swift_without_comments(
        '    func label() -> String {\n'
        '        // was: return "@\\(performer.handle)"\n'
        '        return name\n'
        '    }\n')) == []


def test_a_mention_inside_a_string_survives_the_reading():
    """`swift_code_only` blanks string CONTENTS, which is the whole subject
    here, so this guard reads comment-stripped source instead. If that ever
    changes back, this test is what says so."""
    assert mention_count(swift_without_comments(
        'let x = "@\\(handle)"\n')) == 1


# ── the app as it stands ────────────────────────────────────────────────────


def test_every_mention_asks_whether_the_value_is_an_account():
    named = []
    seen = 0
    for path in swift_files(SOURCES):
        text = swift_without_comments(path.read_text(encoding="utf-8"))
        seen += mention_count(text)
        for declaration in unchecked_mentions(text):
            if (path.name, declaration) in EXEMPT:
                continue
            named.append(f"{path.relative_to(REPO)}: {declaration}")

    assert seen >= FEWEST_MENTIONS, (
        f"only {seen} mentions are built anywhere, against {FEWEST_MENTIONS} "
        "when this was written, so the sweep is reading a renamed shape rather "
        "than the app")
    assert not named, (
        "these declarations put an @ in front of a stored value without asking "
        "PythonBridge.isRealHandle, so a sentinel or a display name is drawn "
        "as an account:\n  "
        + "\n  ".join(named)
        + "\nAsk the shared check, or add the declaration to EXEMPT with what "
          "already answered for it.")


def test_every_exemption_still_names_a_declaration_that_exists():
    """An exemption whose declaration has gone reads as a considered decision
    and covers nothing (L346), and one for a mention that no longer exists
    hides the next one written in its place."""
    live = set()
    for path in swift_files(SOURCES):
        text = swift_without_comments(path.read_text(encoding="utf-8"))
        for declaration in unchecked_mentions(text):
            live.add((path.name, declaration))
    stale = sorted(key for key in EXEMPT if key not in live)
    assert not stale, (
        "these exemptions no longer name a mention that skips the check, so "
        f"they are covering nothing: {stale}")


def test_every_exemption_says_what_answered_for_it():
    empty = sorted(key for key, why in EXEMPT.items() if len(why.split()) < 8)
    assert not empty, (
        "an exemption with no reason beside it is evidence it was never "
        f"reasoned about rather than deliberately chosen (L233): {empty}")
