"""Two source-text rules that were paying an app build to re-prove (#1089).

`VisibleRefusalGuardTests` (three registry entries) and one sweep out of
`WorkWithNoWindowTests` (two more) read nothing but Swift source, and each entry
cost about 29 seconds of rebuilding to prove. They run here in well under a
second between them, the shape #1045 and #1091 proved on the two hardest
matchers in the repository and on the test-target hygiene rules.

Nothing about the rules changes. One reading does, deliberately, and it is a
tightening rather than a loosening: the Swift stripper cut each line at its
first `//`, including one inside a string literal, and said so
("deliberately naive about `//` inside a string literal"). This uses
`swift_without_comments`, which knows the difference. Every place the two
disagree is a place the Swift version discarded real code, so nothing that was
caught before can escape now, and the fixtures below hold both directions.
"""

from __future__ import annotations

from pathlib import Path

from source_text import code_of, swift_files, swift_without_comments, text_of

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "PostRollApp" / "Sources"

#: The functions in this app whose whole purpose is to explain a refusal (#402).
#:
#: Named rather than derived, and checked in BOTH directions, because a stale
#: entry silently exempts whatever drifts into its place (L96).
REFUSAL_PRODUCERS = (
    "StageNavigation.blockedReason",
    "NewEventValidation.refusal",
    "OCRReviewReadiness.confirmHelp",
    "ExportReadiness.blockedReason",
)

#: The shared line that draws a refusal on the screen rather than on hover.
REFUSAL_NOTE = "RefusalNote("

#: How a run BECOMES failed, in every spelling the app uses (#872).
#:
#: The state, not one spelling of it. The first version of this sweep looked for
#: `markFailed`, which is how five of the managers record a failure, and
#: `ExportManager` is not one of them: it sets a failed phase and deactivates
#: instead. So the longest running work in the app was the one kind that still
#: failed in silence, and the sweep reported all clear while checking five real
#: sites. A sweep that enumerates its subjects by one spelling of the thing it
#: cares about exempts everything reaching the same state another way, and it
#: reads as real coverage because the subjects it did find are real (L247).
FAILURE_SPELLINGS = (".markFailed(", "phase: .failed(", "phase = .failed(")

#: What a failure path has to say out loud.
THE_ANNOUNCEMENT = "notifyWorkFailed("

#: How many lines after the failure the announcement may appear on.
#:
#: Proximity rather than order or exact form, because the point is that the two
#: live together, not that they are written a particular way.
ANNOUNCEMENT_WINDOW = 9

#: JobTracker DEFINES markFailed. It does not call it about any particular piece
#: of work and has no event name to announce.
NOT_A_FAILURE_SITE = "JobTracker.swift"

#: The fewest failure paths a working sweep finds. There have been five since
#: #718, so fewer means the sweep is reading the wrong thing rather than the app
#: having fewer (L98).
A_REAL_FAILURE_SWEEP = 5


def code(text: str) -> str:
    """`text` with its comments gone, string literals left in.

    `swift_without_comments` rather than a cut at the first `//`: a guard that
    matches on raw source can be satisfied by prose ABOUT the thing, including a
    comment explaining that the thing was removed, which is indistinguishable
    from working (L103). It matters here specifically: the tooltip-only site
    carried a comment claiming it said which work was missing, and that comment
    was true of the intent and false of the screen.

    Trailing comments count, not only whole comment lines, because
    `EmptyView() // RefusalNote(...)` satisfied every check below until the
    mutation registry recorded exactly that break (#416).

    String literals are kept, because a token written inside one is still that
    token written in code as far as these rules are concerned, and stripping
    them would quietly widen every check.
    """
    return swift_without_comments(text)


def code_in(subdirectory: str) -> str:
    """Every Swift file directly under `Sources/<subdirectory>`, decommented.

    One level, not a walk, which is what `contentsOfDirectory` did.
    """
    directory = SOURCES / subdirectory
    files = sorted(path for path in directory.iterdir() if path.suffix == ".swift")
    assert files, (
        f"no Swift files directly under Sources/{subdirectory}, so every rule "
        "reading this is asking questions of an empty string (L98)"
    )
    return "\n".join(code(text_of(path)) for path in files)


def missing_producers(services: str, views: str) -> list[str]:
    """Refusal producers that are undeclared, or declared and never called.

    A producer nothing calls is a refusal nobody can be shown, which looks
    exactly like one that works (L46).
    """
    problems: list[str] = []
    for producer in REFUSAL_PRODUCERS:
        function = producer.rsplit(".", 1)[-1]
        if f"func {function}" not in services:
            problems.append(f"{producer} is not declared in Services any more")
        if producer not in views:
            problems.append(
                f"{producer} is not called by any screen, so it can never be seen")
    return problems


def silent_failure_paths(root: Path | None = None) -> tuple[list[str], int]:
    """Places a run is marked failed with no announcement near it, and how many
    failure paths were examined at all.

    The count is not decoration. No offenders is what a sweep that read nothing
    also reports, and the caller holds it to a floor (L98).

    A sweep over what is REACHABLE in Sources rather than a list kept by hand:
    announcing a failure is a thing each manager does in its own failure path,
    which is exactly the shape of a list that goes stale. A sixth manager added
    later would be silent, nothing would fail, and the gap would be invisible
    because the other five still announce (L96).
    """
    silent: list[str] = []
    checked = 0
    for path in swift_files(root if root is not None else SOURCES):
        if path.name == NOT_A_FAILURE_SITE:
            continue
        lines = code_of(path).split("\n")
        for index, line in enumerate(lines):
            if not any(spelling in line for spelling in FAILURE_SPELLINGS):
                continue
            checked += 1
            window = "\n".join(lines[index:index + ANNOUNCEMENT_WINDOW])
            if THE_ANNOUNCEMENT not in window:
                silent.append(f"{path.name}:{index + 1}")
    return silent, checked
