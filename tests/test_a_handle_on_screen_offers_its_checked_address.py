"""A handle drawn as a link offers the checked address the screen holds (#987).

The enrichment step fetches a candidate account's profile and confirms it
before the handle is written down, and since #987 the performer record keeps
that address. Every surface that turns a handle into something openable is
supposed to prefer it, falling back to the address built by convention only
where there is none, which is the rule `ProfileLink` implements.

Nothing checked that a surface actually hands it over. The parameter has no
default, so a new call site cannot forget it (L168), but it can pass `nil` and
compile, and then the screen goes on opening a constructed address while the
call site reads as correct. That is the same slow discovery #1112 describes for
`isRealHandle`: found by hand, one surface at a time.

So this reads the calls rather than the intent. `nil` written at a call site is
a claim that this screen has no checked address to offer, and the ones that do
hold one are exactly the screens where the constructed address is a guess
standing in for a fetched fact.

A call that genuinely has nothing (a test fixture, a screen with no event in
reach) belongs in EXEMPT with the reason, rather than being left silent for the
next reader to wonder about (L129, L233).
"""

from __future__ import annotations

import re
from pathlib import Path

from tests.source_text import code_of, swift_code_only, swift_files

REPO = Path(__file__).resolve().parent.parent
SOURCES = REPO / "PostRollApp" / "Sources"

# What a surface is constructed with, and the argument carrying the checked
# address into it. Both take it without a default, so a call site says one way
# or the other.
LINK_SURFACES = {
    "ProfileHandleText": "storedProfileURL",
    "AccountNumbersSheet": "checkedProfileURL",
}

# file name -> why a call there has nothing checked to pass. Empty, and that is
# the current truth: every surface drawing a handle can reach the day's
# performers.
EXEMPT: dict[str, str] = {}

# Below this the sweep is not measuring the app any more, it is measuring a
# rename (L98, L320). Four calls today: two in the collaborator panel, one in
# each of the two screens that present the numbers form.
FEWEST_CALLS = 4


def calls(text: str, name: str) -> list[str]:
    """The argument text of every `name(...)` construction in `text`.

    Balanced rather than up to the first `)`, because these calls carry
    closures and nested calls of their own.
    """
    found = []
    for start in re.finditer(rf"\b{name}\(", text):
        i, depth = start.end(), 1
        while i < len(text) and depth:
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
            i += 1
        found.append(text[start.end():i - 1])
    return found


def argument(call: str, label: str) -> str | None:
    """What `label:` was passed, or None when the call does not pass it."""
    at = re.search(rf"\b{label}\s*:\s*", call)
    if not at:
        return None
    rest = call[at.end():]
    depth = 0
    for i, char in enumerate(rest):
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            return rest[:i].strip()
    return rest.strip()


def offering_nothing_checked(text: str) -> list[str]:
    """The surfaces in `text` handed no checked address at all.

    `nil` and an omitted argument are one answer here: both say this screen
    offers nothing, and only one of them is a compile error.
    """
    named = []
    for surface, label in LINK_SURFACES.items():
        for call in calls(text, surface):
            if (argument(call, label) or "nil") == "nil":
                named.append(surface)
    return named


# ── the reading itself, on text this file controls ──────────────────────────


def test_a_surface_handed_nil_is_named():
    assert offering_nothing_checked(
        "ProfileHandleText(handle: h, storedProfileURL: nil)") == ["ProfileHandleText"]


def test_a_surface_handed_a_real_expression_is_not_named():
    assert offering_nothing_checked(
        "ProfileHandleText(handle: h, storedProfileURL: candidate.profileURL)") == []


def test_a_surface_that_omits_the_argument_is_named_too():
    """It cannot compile today, and it is the same answer if the default ever
    comes back: this screen offers nothing checked."""
    assert offering_nothing_checked("AccountNumbersSheet(handle: h)") \
        == ["AccountNumbersSheet"]


def test_an_argument_carrying_a_call_of_its_own_is_read_whole():
    """The address is routinely resolved by a call with commas inside it, and
    reading to the first comma would take `ProfileLink.checkedProfile(for: h`
    as the value and find nothing wrong with it either way."""
    assert argument(
        "handle: h, checkedProfileURL: ProfileLink.checkedProfile(for: h, in: p), stats: nil",
        "checkedProfileURL") == "ProfileLink.checkedProfile(for: h, in: p)"


def test_a_call_written_in_a_comment_is_not_a_call():
    """Blanked before the sweep reads it, or a comment showing what NOT to do
    fails the guard, and a comment quoting the correct form satisfies it
    (L103)."""
    commented = swift_code_only(
        "// ProfileHandleText(handle: h, storedProfileURL: nil)\n"
        "ProfileHandleText(handle: h, storedProfileURL: candidate.profileURL)")
    assert offering_nothing_checked(commented) == []


# ── the app as it stands ────────────────────────────────────────────────────


def test_every_surface_drawing_a_handle_offers_what_it_has_checked():
    named = []
    seen = 0
    for path in swift_files(SOURCES):
        code = code_of(path)
        seen += sum(len(calls(code, surface)) for surface in LINK_SURFACES)
        if path.name in EXEMPT:
            continue
        for surface in offering_nothing_checked(code):
            named.append(f"{path.relative_to(REPO)}: {surface}")

    assert seen >= FEWEST_CALLS, (
        f"only {seen} of these surfaces are constructed anywhere, against "
        f"{FEWEST_CALLS} when this was written, so the sweep is reading a "
        "renamed view rather than the app")
    assert not named, (
        "these screens draw a handle as a link and pass no checked address, so "
        "they open an address built by convention while one that was fetched "
        "and confirmed sits on the performer record:\n  "
        + "\n  ".join(named)
        + "\nPass the stored address, or name the file in EXEMPT with why it "
          "has none.")


def test_every_exemption_names_a_file_that_is_still_there():
    """An exemption for a file that has gone reads as a considered decision and
    silently covers nothing (L346)."""
    present = {path.name for path in swift_files(SOURCES)}
    missing = sorted(name for name in EXEMPT if name not in present)
    assert not missing, f"exempted files that no longer exist: {missing}"
