"""No Swift test may construct a store that reads Dan's live data (#722).

`NoScreenForcesTheWindowBiggerTests` hosted every screen in the app with
`AnalyticsStore()`, which resolved through `AppPaths.analyticsFile` to the real
imported Instagram history, and `HashtagStore()`, which read his real
UserDefaults. The test scheme sets no `POSTROLL_DATA_DIR`, the only thing that
redirects that root, so nothing structural kept the suite off live data (L2).

Both only READ, which is why nothing had gone wrong. The exposure is that a
rendered screen picking up a write, or a future store that saves on load, would
write over a history whose only other copy is a Meta export Dan has to
re-download (L5).

The enforcement is the compiler, not this file: the initializers that name the
live locations sit behind `#if !POSTROLL_TESTS`, so a test that omits the path
does not build. These tests prove that arrangement is still in place, because a
compile-time guard is the one kind that cannot be seen to go red in a suite, and
they name the defect in the terms it was filed in.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.source_text import (
    swift_as_the_test_bundle_sees_it,
    swift_code_only,
    swift_without_comments,
)

REPO = Path(__file__).resolve().parent.parent
SOURCES = REPO / "PostRollApp" / "Sources"
SWIFT_TESTS = REPO / "PostRollApp" / "Tests"

# An initializer parameter whose default value is one of the app's live
# locations. Derived from the source rather than a list of store names, so a
# store added tomorrow is covered by the same rule (L96).
LIVE_DEFAULT = re.compile(r"init\([^)]*=\s*AppPaths\.[A-Za-z]", re.S)

# The two stores the render sweep reached, each with what to pass instead. Their
# no-argument form is what a future test reaches for, so it is named here in the
# plain terms the defect was reported in, on top of the compiler refusing it.
# Each remedy names the argument that store actually takes: a message telling
# someone to pass a file to a store that takes a flag sends them somewhere that
# cannot help (L111).
# A live location handed straight to a store, which reaches the same file the
# bare form did while looking deliberate. No test does this today, and the ban
# is worth having because the obvious way to silence the compiler's refusal is
# to pass the very path it was protecting.
LIVE_ARGUMENT = re.compile(r"(?:fileURL|storeURL|dataRoot|root)\s*:\s*AppPaths\.[A-Za-z]")

BARE_STORES = {
    "AnalyticsStore": "hand it a fileURL in a temporary directory, the way "
                      "InsightsWorkManagerTests does",
    "HashtagStore":   "pass loadingSaved: false, the way HostedControlLegibilityTests "
                      "does, so Dan's saved tags are not read",
}


def _swift_files(root: Path) -> list[Path]:
    files = sorted(root.rglob("*.swift"))
    assert files, f"no Swift files under {root}, so this guard checked nothing"
    return files


def _hits(pattern: re.Pattern[str], text: str) -> list[int]:
    """The 1-based lines of `text` where `pattern` matches."""
    return [text[:m.start()].count("\n") + 1 for m in pattern.finditer(text)]


def _bare(store: str) -> re.Pattern[str]:
    return re.compile(rf"\b{store}\s*\(\s*\)")


@pytest.mark.parametrize("store", sorted(BARE_STORES))
def test_no_swift_test_constructs_a_store_with_no_explicit_source(store):
    remedy = BARE_STORES[store]
    offenders = []
    for path in _swift_files(SWIFT_TESTS):
        # Code only: AppOwnersTests carries a Swift snippet in a string literal
        # as another guard's fixture, and matching that named an innocent file
        # (L104).
        text = swift_code_only(path.read_text(encoding="utf-8"))
        offenders += [f"{path.relative_to(REPO)}:{line}"
                      for line in _hits(_bare(store), text)]

    assert not offenders, (
        f"{store}() with no argument in a test reads Dan's live data: "
        f"{', '.join(offenders)}. To fix it, {remedy}. A test suite must be "
        "structurally unable to reach live data (L2)."
    )


def test_no_swift_test_hands_a_store_one_of_the_live_locations():
    offenders = []
    for path in _swift_files(SWIFT_TESTS):
        text = swift_code_only(path.read_text(encoding="utf-8"))
        offenders += [f"{path.relative_to(REPO)}:{line}"
                      for line in _hits(LIVE_ARGUMENT, text)]

    assert not offenders, (
        "a test hands a store one of the app's live locations: "
        f"{', '.join(offenders)}. That reaches Dan's real data just as surely as "
        "omitting the argument did, and it is the obvious way to quieten the "
        "compiler's refusal. Point it at a temporary directory instead (L2)."
    )


def test_no_store_the_test_bundle_compiles_defaults_to_a_live_location():
    offenders = []
    for path in _swift_files(SOURCES):
        text = swift_as_the_test_bundle_sees_it(
            swift_code_only(path.read_text(encoding="utf-8")))
        offenders += [f"{path.relative_to(REPO)}:{line}"
                      for line in _hits(LIVE_DEFAULT, text)]

    assert not offenders, (
        "an initializer the TEST BUNDLE compiles defaults a parameter to one of "
        f"the app's live locations: {', '.join(offenders)}. A test that omits "
        "the argument then reads or writes Dan's real data, and remembering to "
        "pass a temporary path is not structural (L2). Put the live default "
        "behind #if !POSTROLL_TESTS, the way AnalyticsStore does, so omitting "
        "it is a build error."
    )


def test_the_app_still_has_a_store_of_its_own_to_build():
    # The other half of the rule. Compiling the live initializer out of the test
    # bundle is only correct if the app itself still has one, and a guard that
    # only ever checks the absence of something is satisfied by deleting both
    # halves (L159).
    analytics = swift_code_only(
        (SOURCES / "Services" / "AnalyticsStore.swift").read_text(encoding="utf-8"))
    assert LIVE_DEFAULT.search(analytics) or "AppPaths.analyticsFile" in analytics, (
        "AnalyticsStore no longer names the live analytics file anywhere, so the "
        "app has no store of its own to build"
    )
    assert "AppPaths.analyticsFile" not in swift_as_the_test_bundle_sees_it(analytics), (
        "the live analytics file is named in code the test bundle compiles"
    )


# ---------------------------------------------------------------------------
# The controls
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("store", sorted(BARE_STORES))
def test_the_scan_can_still_see_a_bare_store(store):
    """A scan that has stopped matching reports every file clean (L98).

    Not hypothetical: the first version of this guard read a raw string literal
    as if it carried an interpolation, ran off the end of `AppOwnersTests`
    looking for a closing paren, and saw nothing in that file at all. It
    reported a pass.
    """
    offender = swift_code_only(f"    .environment({store}())\n")
    assert _hits(_bare(store), offender) == [1]


def test_the_scan_can_still_see_a_live_default():
    offender = swift_as_the_test_bundle_sees_it(swift_code_only(
        "final class Thing {\n    init(fileURL: URL = AppPaths.analyticsFile) {}\n}\n"))
    assert _hits(LIVE_DEFAULT, offender) == [2]


def test_a_live_default_the_app_alone_compiles_is_not_an_offence():
    # The other direction. A control that only ever proves the guard FIRES will
    # accept one that fires on everything, and this arrangement is exactly what
    # the fix relies on (L104).
    allowed = swift_as_the_test_bundle_sees_it(swift_code_only(
        "final class Thing {\n#if !POSTROLL_TESTS\n"
        "    convenience init() { self.init(fileURL: AppPaths.analyticsFile) }\n"
        "#endif\n}\n"))
    assert _hits(LIVE_DEFAULT, allowed) == []


def test_the_scan_can_still_see_a_live_location_handed_over():
    offender = swift_code_only(
        "        let store = AnalyticsStore(fileURL: AppPaths.analyticsFile)\n")
    assert _hits(LIVE_ARGUMENT, offender) == [1]


def test_reading_a_live_location_without_opening_it_is_not_an_offence():
    # AppPathsTests asserts what the paths resolve to, which is the reason those
    # names exist. A rule that fired on every mention of them would fail the one
    # file whose job is to check them, and would be turned off (L104).
    innocent = swift_code_only(
        "        XCTAssertEqual(AppPaths.analyticsFile,\n"
        "                       AppPaths.root.appendingPathComponent(\"analytics.json\"))\n")
    assert _hits(LIVE_ARGUMENT, innocent) == []
