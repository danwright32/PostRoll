"""The test-target hygiene rules that only read SOURCE TEXT, in Python (#1089).

These lived in `TestTargetHygieneTests`, where every one of them cost an app
build to re-prove. The guard sweep re-proves the registry entries a diff
touches, and seven of them named that class: not one made a drawing call, and
every one of them read nothing but text. Measured on 2026-08-31, six classes in
the Swift suite are in that state and hold 27 entries between them, about
thirteen minutes of rebuilding on any diff that selects them. This is the first
of the six, following the shape #1045 proved twice on the two hardest matchers
in the repository.

Nothing about the rules changes here. They are the same predicates over the same
text, and the fixtures that prove each matcher sees every spelling are carried
across, because that is the only thing that CAN prove them: the tree is clean,
so a matcher that sees one spelling and a matcher that sees three give the same
silent pass over the real files (L48, L159). Two of these matchers had already
narrowed once in Swift and were caught by `check_guards` rather than by the
codebase, which is the same story.

The reading is deliberately per rule rather than one shared stripping, because
the Swift originals differed and the difference was load bearing:

* the flag counter drops WHOLE LINES beginning with `#`, because project.yml is
  YAML and `#` is its comment marker, not Swift's;
* the suite and shipping-initialiser scanners drop lines beginning with `//` or
  `*`, which is what the Swift versions did, so a doc comment about a class or
  an initialiser is not itself an offence (L103);
* the import and launch scans read the file as written, because the needle they
  look for cannot be produced by prose that is not itself the offence.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
APP = REPO_ROOT / "PostRollApp"
TESTS_DIR = APP / "Tests"
PBXPROJ = APP / "PostRoll.xcodeproj" / "project.pbxproj"
MANIFEST = APP / "project.yml"
UI_TESTS = APP / "UITests" / "AppEntryPointUITests.swift"

#: Spelled in pieces so this module does not itself contain the token. The
#: counter below reads project.yml rather than this file, so it is only
#: tidiness, but naming it once keeps the fixtures honest about what they build.
TEST_ONLY_FLAG = "POSTROLL" + "_TESTS"

#: Likewise: the import guard's needle, built from parts so no file carrying
#: this module's text can be mistaken for an offender.
TESTABLE_IMPORT = "@testable import " + "PostRoll"

#: Every `.swift` name mentioned anywhere in the generated project. Read out of
#: project.pbxproj rather than assumed, because that file IS the answer to what
#: the bundle contains.
A_SWIFT_NAME = re.compile(r"[A-Za-z0-9_+\-]+\.swift")

#: An XCTestCase subclass declaration, at the start of a stripped line.
A_SUITE = re.compile(r"^(?:final\s+)?class\s+([A-Za-z0-9_]+)\s*:\s*XCTestCase")

#: `AppState()`, the SHIPPING initialiser: the one that reads the real
#: events.json and then runs the launch sweeps against whatever came back.
#:
#: Spelled as a regular expression rather than a plain needle so this file is
#: not itself an offender: the pattern's own text carries backslashes and
#: therefore does not match the pattern.
A_SHIPPING_APP_STATE = re.compile(r"\bAppState\(\s*\)")

#: The test seam, whose every use is the correct way to build one.
THE_SEAM = "AppState(events:"

#: The seam's DECLARATION, which is what the two AppState.swift rules read.
THE_SEAM_DECLARATION = "init(events:"

#: How the GUI suite starts the app. Each call costs about 42 seconds on the
#: runner and the testing in it costs almost none of that (#864).
A_LAUNCH = "LaunchedApp.launch("


def _without_swift_comment_lines(source: str) -> list[str]:
    """`source` as stripped lines, with comment lines dropped.

    What `suiteNames` and `shippingAppStateLines` did in Swift. A guard that is
    green on prose is indistinguishable from one that works, and one that goes
    RED on prose accuses a comment of something the comment did not do (L103,
    L11).

    Lines rather than a character-level strip, deliberately: the Swift versions
    worked in lines and the line NUMBER is what the offender list reports.
    """
    return [line.strip() for line in source.split("\n")]


def _is_comment(line: str) -> bool:
    return line.startswith("//") or line.startswith("*")


def registered_names(pbxproj: str) -> set[str]:
    """The Swift file names the generated project compiles."""
    return set(A_SWIFT_NAME.findall(pbxproj))


def on_disk_names(directory: Path) -> set[str]:
    """The `.swift` files actually sitting in `directory`."""
    return {path.name for path in directory.iterdir() if path.suffix == ".swift"}


def suite_names(source: str) -> list[str]:
    """The XCTestCase subclasses declared in one file's source."""
    found: list[str] = []
    for line in _without_swift_comment_lines(source):
        if _is_comment(line):
            continue
        match = A_SUITE.match(line)
        if match:
            found.append(match.group(1))
    return found


def shipping_app_state_lines(source: str) -> list[int]:
    """The 1-based lines where a source builds an AppState the shipping way."""
    return [
        number
        for number, line in enumerate(_without_swift_comment_lines(source), start=1)
        if not _is_comment(line) and A_SHIPPING_APP_STATE.search(line)
    ]


def seam_uses(source: str) -> int:
    """How many times a source reaches for the test seam.

    Only ever used as a positive control: a scanner that finds no construction
    at all would report every file clean, and clean is indistinguishable from
    blind (L98).
    """
    return source.count(THE_SEAM)


@dataclass(frozen=True)
class Scan:
    """What a directory scan found AND how many files it managed to open.

    Two values rather than one, because they answer different questions and a
    single list cannot (L53): the offenders are the verdict, and the count is
    what says the verdict was taken at all.
    """

    offenders: list[str]
    read: int


def offenders(directory: Path, registered: set[str], *, containing: str,
               excluding: str = "") -> Scan:
    """Files carrying `containing`, considering only ones the project compiles.

    The project's own list rather than the directory, so a stray or half-written
    file cannot fail a guard about what the bundle holds. The orphan guard is
    the one that reads the directory, because on disk but not in the project is
    the whole thing it looks for.
    """
    names = sorted(registered - {excluding} if excluding else registered)
    carrying: list[str] = []
    read = 0
    for name in names:
        path = directory / name
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            # Registered but unreadable right now. Absence is not evidence of
            # the needle, and guessing either way is worse than saying no. The
            # count beside it is what stops that answer standing in for a clean
            # sweep: no offenders is what a scan that opened NOTHING reports
            # too, and the caller asserts a floor on it (L98, L10).
            continue
        read += 1
        if containing in text:
            carrying.append(name)
    return Scan(offenders=carrying, read=read)


def definitions_of_the_test_only_flag(manifest: str) -> int:
    """How many times the manifest DEFINES the test-only flag.

    Named for what it counts rather than for the rule it serves. The first
    spelling here began with the collector's own prefix, and pytest took the
    helper for a TEST the moment the guard file imported it, then errored on a
    fixture named after its argument. A helper imported into a test module is
    collected by its name like anything else.

    Comment lines are dropped before counting, because a comment cannot define
    a build setting: counting one is a false accusation, and the message it
    produces names a cause that did not happen (#853, L11). Dropping them is
    not a loosening, because a commented out definition sets nothing, and a real
    definition on the app target is still caught wherever it appears.
    """
    code = "\n".join(
        line for line in manifest.split("\n") if not line.strip().startswith("#")
    )
    return code.count(TEST_ONLY_FLAG)


def seam_signature(source: str) -> str | None:
    """AppState's test-seam signature, or None if the seam is gone.

    Gone entirely is fine and is not this module's business: what is protected
    is that the seam cannot be reached from the app and cannot point at live
    data, never that it exists.

    Matched on the PREFIX rather than the whole signature. The Swift version
    looked for `init(events: [Event])` exactly, and on 2026-08-13 the seam
    gained a storeURL parameter: the exact match then found nothing, took the
    early return, and passed while checking nothing at all. `check_guards`
    reported it as SURVIVED (L103).
    """
    start = source.find(THE_SEAM_DECLARATION)
    if start < 0:
        return None
    rest = source[start + len(THE_SEAM_DECLARATION):]
    end = rest.find(") {")
    if end < 0:
        return ""
    return rest[:end]


def seam_is_behind_the_test_only_flag(source: str) -> bool | None:
    """Whether the seam sits inside an open `#if POSTROLL_TESTS`, or None if gone.

    Counted rather than parsed, which is what the Swift version did: more opens
    than closes before the seam means it is inside one.
    """
    start = source.find(THE_SEAM_DECLARATION)
    if start < 0:
        return None
    before = source[:start]
    return before.count(f"#if {TEST_ONLY_FLAG}") > before.count("#endif")


def launches(ui_test_source: str) -> int:
    """How many times the GUI suite starts the app, ignoring comment lines."""
    code = "\n".join(
        line
        for line in _without_swift_comment_lines(ui_test_source)
        if not _is_comment(line)
    )
    return code.count(A_LAUNCH)
