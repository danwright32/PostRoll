"""#951: a screen that builds its own store draws whatever was left behind.

#937 gave seven screens a parameter for every store they read while drawing,
defaulting to the shared instance, which is what made them renderable for review
at all. Before that, building a screen reached for `HandleBook.shared`,
`AccountBook.shared`, `TimingStore.shared`, `PreviewGraphicsManager.shared` or
`ProgramPDFBakery.shared` directly.

Nothing kept that true. A new screen written the old way, or a new store added to
one of the seven, reaches for the shared instance again and the review sheet
quietly starts picturing whatever the run before it left behind. Same shape as
`AppOwnersTests`, which exists because a second hand-kept list of work owners
fell behind and crashed every rendered screen (#718).

## What this checks, and what it does not

A STORED PROPERTY whose initialiser is `SomeType.shared`. That is the shape #937
fixed and the one that decides what a rendered screen shows: the property is
built when the view is, so the screen is bound to whatever that instance holds.

A default ARGUMENT is the remedy, not the defect, and it is not matched: Swift
writes it `book: HandleBook = .shared`, with the type inferred, so it carries no
qualified `SomeType.shared` at all. The rule and its remedy are therefore told
apart by their spelling rather than by a list.

Deliberately NOT every reach. `PythonBridge.shared` inside a button's action is a
process-wide service being called when somebody presses something, and it has no
bearing on what the screen draws; sweeping those in would fire on nearly every
screen and stop being read (L36). If one of those ever needs replacing in a test,
it needs an injection point for its own reason, not this one.

Which types count is DERIVED: a type declared under `PostRollApp/Sources`. So
`NSWorkspace.shared` and `NSApplication.shared` are outside by construction
rather than by being remembered (L96, L41).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from source_text import swift_without_comments

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "PostRollApp" / "Sources"
VIEWS = SOURCES / "Views"

#: A stored property whose initialiser is a qualified `.shared`.
STORED_SHARED = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:private |public |internal |fileprivate |static |final )*"
    r"(?:var|let)\s+\w+\s*(?::\s*[^=]+?)?=\s*([A-Z]\w*)\.shared")

#: A type declared by this app.
DECLARED = re.compile(
    r"^(?:final )?(?:public )?(?:class|struct|enum|actor) (\w+)", re.M)

#: A screen that may reach for a shared instance while being built, and why.
#:
#: Empty, and that is the current truth rather than a placeholder. An entry
#: carries the REASON, because an exemption with no reason is evidence nobody
#: reasoned about it (L233).
MAY_REACH: dict[str, str] = {}


def app_types() -> set[str]:
    found: set[str] = set()
    for path in SOURCES.rglob("*.swift"):
        found |= set(DECLARED.findall(path.read_text(encoding="utf-8")))
    assert len(found) > 100, (
        f"only {len(found)} types were found under {SOURCES}, which is not this "
        f"app: the sweep below would treat almost everything as somebody "
        f"else's type and check nothing")
    return found


def reaches() -> list[tuple[str, int, str]]:
    """Every stored property in a view built from a shared instance."""
    mine = app_types()
    found: list[tuple[str, int, str]] = []
    for path in sorted(VIEWS.rglob("*.swift")):
        code = swift_without_comments(path.read_text(encoding="utf-8"))
        for number, line in enumerate(code.splitlines(), 1):
            match = STORED_SHARED.match(line)
            if match and match.group(1) in mine:
                found.append((str(path.relative_to(SOURCES)), number,
                              match.group(1)))
    return found


def test_the_sweep_reaches_the_view_layer():
    """The positive control. A sweep finding no view files, or treating none of
    the app's types as its own, would report a clean layer and every check here
    would pass on an empty answer (L98, L100)."""
    views = list(VIEWS.rglob("*.swift"))

    assert len(views) > 30, f"only {len(views)} view files found under {VIEWS}"
    assert "HandleBook" in app_types()


def test_the_matcher_still_finds_the_shape_it_is_about():
    """And the remedy is still told apart from the defect. Both directions,
    because a matcher that found everything would be as useless as one that
    found nothing (L159)."""
    reached = "    private var deepLinks = DeepLinkInbox.shared"
    taken = "    init(book: HandleBook = .shared) {"

    assert STORED_SHARED.match(reached), (
        "the matcher no longer sees a store reached for while the screen is "
        "built, so this whole file guards nothing")
    assert not STORED_SHARED.match(taken), (
        "the matcher fires on a default argument, which is the REMEDY: nobody "
        "could satisfy this check (L109)")


def test_no_screen_builds_its_own_store():
    """One assertion rather than one per offender, so the zero case is a
    PASS rather than an empty parameter set that pytest reports as a skip. A
    check that reads as skipped when it is satisfied is one nobody can tell
    from a check that stopped running (L98)."""
    offenders = [f"{file} line {line} builds {store}.shared"
                 for file, line, store in reaches() if file not in MAY_REACH]

    assert not offenders, (
        "these build a store while the screen is built, so they draw whatever "
        "the run before them left behind and the review sheet pictures that "
        "rather than a state anybody chose (#951, #937). Take it as a "
        "parameter defaulting to the shared instance, the way OCRReviewView "
        "takes its HandleBook, or add the file to MAY_REACH with the reason it "
        "genuinely has to:\n" + "\n".join(offenders))


def test_the_exemptions_all_name_a_file_that_still_reaches():
    """A stale entry excuses a real failure silently (L233, L217)."""
    named = {site[0] for site in reaches()}
    stale = sorted(set(MAY_REACH) - named)

    assert not stale, (
        f"these exemptions name no screen that reaches any more: {stale}. "
        f"Either it was fixed and the entry should go, or it was renamed and "
        f"the entry now excuses nothing while looking like it does")
