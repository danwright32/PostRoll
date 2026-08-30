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
from functools import lru_cache
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
# A live location is not only a path. `PostingPresetStore` defaulted its
# `defaults:` parameter to `UserDefaults.standard`, which is Dan's real posting
# preference, and `SettingsView` took that default while being compiled into the
# test bundle (#727). Reading a preference is not reading a photo history, and
# it is the same shape: the store the app runs on, reached by a test that said
# nothing about where to look.
LIVE_DEFAULT = re.compile(
    r"init\([^)]*=\s*(?:AppPaths\.[A-Za-z]|UserDefaults\.standard|\.standard\b)", re.S)

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

# Dan's real preferences, named anywhere in code the test bundle compiles (#738).
#
# Eleven places named this inline, and four of them WROTE: the hashtag store's
# save, the timing store's setter, the export folder ExportManager remembers, and
# every write through HandleBook.shared, whose store is a property precisely so a
# test can point it elsewhere and whose singleton is built by an initializer that
# takes the live one anyway.
#
# A rule about the DOMAIN rather than a list of stores, because the list is what
# went out of date: #722 closed the two stores it knew about, and the eight that
# reached the same store without an initializer to compile out were untouched
# (L96). One named home for it, `AppPreferences.store`, whose live branch is the
# only thing the app compiles and the test bundle does not.
LIVE_PREFERENCES = re.compile(r"UserDefaults\.standard|(?<![\w.])\.standard\b")

# A shared instance built from one of the live locations (#945).
#
# `LIVE_DEFAULT` reads initializer PARAMETERS, so it never saw
# `AccountBook.shared = AccountBook(fileURL: AppPaths.accountsFile)`: nothing is
# defaulted there, the live path is passed outright, and `AccountBook.init`
# calls `load()`, so the first touch of that property in the test bundle read
# Dan's real follower counts. Nothing was wrong on the day only because no
# accounts.json existed yet; the file appears the first time an export records
# a count, and from then on the suite would read real numbers about real people
# on a path nobody would think to check (L222).
#
# A rule about the SHAPE rather than a list of singletons, on the reasoning that
# put `AppPreferences` in place: a list only ever checks what somebody
# remembered to list (L96).
#
# Lowercase after the dot on purpose. `AppPaths.Layout` and
# `AppPaths.ProjectRootProblem` are TYPES, and `DataInventory` builds a layout
# on a root of its own, which reaches nothing.
LIVE_SINGLETON = re.compile(r"static\s+(?:let|var)\s+\w+[^\n=]*=[^\n]*\bAppPaths\.[a-z]")

BARE_STORES = {
    "AnalyticsStore": "hand it a fileURL in a temporary directory, the way "
                      "InsightsWorkManagerTests does",
    "HashtagStore":   "pass loadingSaved: false, the way HostedControlLegibilityTests "
                      "does, so Dan's saved tags are not read",
    "PostingPresetStore":
                      "pass defaults: a UserDefaults(suiteName:) of your own, the "
                      "way PostingPresetTests does, so Dan's real posting layout "
                      "is neither read nor written",
}


@lru_cache(maxsize=None)
def _swift_files(root: Path) -> tuple[Path, ...]:
    """Every Swift file under `root`, walked once per run rather than per test.

    Memoised because 22 parametrised tests each re-walked the tree and re-read
    every file, 17.5s of the Python suite for one answer that cannot change
    inside a run (#1018).

    Keyed on the root, so a caller that injects its own directory still gets its
    own walk. The memo is the shared no-argument case, not the parameter.

    The emptiness assertion stays INSIDE the memoised function on purpose. A
    memo that can store an empty scan hands the same nothing to every reader at
    once, and each of them then reports a clean run over no files at all
    (L286, L98). Raising here means nothing is ever stored.
    """
    files = tuple(sorted(root.rglob("*.swift")))
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


def test_no_singleton_the_test_bundle_compiles_is_built_from_a_live_location():
    offenders = []
    for path in _swift_files(SOURCES):
        text = swift_as_the_test_bundle_sees_it(
            swift_code_only(path.read_text(encoding="utf-8")))
        offenders += [f"{path.relative_to(REPO)}:{line}"
                      for line in _hits(LIVE_SINGLETON, text)]

    assert not offenders, (
        "a shared instance the TEST BUNDLE compiles is built from one of the "
        f"app's live locations: {', '.join(offenders)}. Nothing has to pass an "
        "argument to reach it, so the first test that touches the property "
        "reads Dan's real data, and no parameter rule can see it because "
        "nothing is defaulted. Give the test bundle a scratch instance behind "
        "#if POSTROLL_TESTS, the way AppPreferences.store does (L2)."
    )


def test_no_code_the_test_bundle_compiles_names_the_live_preferences():
    offenders = []
    for path in _swift_files(SOURCES):
        text = swift_as_the_test_bundle_sees_it(
            swift_code_only(path.read_text(encoding="utf-8")))
        offenders += [f"{path.relative_to(REPO)}:{line}"
                      for line in _hits(LIVE_PREFERENCES, text)]

    assert not offenders, (
        "these name Dan's real UserDefaults in code the test bundle compiles: "
        f"{', '.join(offenders)}. Reading them makes a test's result depend on "
        "his machine, and the saves among them write his global hashtags, his "
        "handle book and his export folder for real. Go through "
        "AppPreferences.store, whose live branch is compiled out of the test "
        "bundle (L2, L201)."
    )


def test_the_app_still_has_preferences_of_its_own():
    # The other half, on the same reasoning as the analytics one below: a rule
    # that only ever checks the ABSENCE of something is satisfied by deleting
    # both halves, and then the app has no preferences at all (L159).
    home = REPO / "PostRollApp" / "Sources" / "Services" / "AppPreferences.swift"
    assert home.is_file(), "AppPreferences no longer exists, so nothing names the app's own store"
    code = swift_code_only(home.read_text(encoding="utf-8"))
    assert "UserDefaults.standard" in code, (
        "AppPreferences no longer names UserDefaults.standard anywhere, so the "
        "shipping app has no preferences to read")
    assert not LIVE_PREFERENCES.search(swift_as_the_test_bundle_sees_it(code)), (
        "AppPreferences names the live preferences in code the test bundle "
        "compiles, which is the one file where that must be behind "
        "#if !POSTROLL_TESTS")


def test_the_scratch_suite_is_not_one_of_the_apps_own_domains():
    """A suite named after a bundle id IS that bundle's own preferences.

    `UserDefaults(suiteName:)` is documented as not accepting the caller's own
    bundle identifier, and the two names sit in different files, so nothing
    otherwise holds them apart. If they ever met, every test would be writing
    the domain this arrangement exists to protect while reading as isolated,
    which is the one failure this cannot report on its own (L70).
    """
    home = (REPO / "PostRollApp" / "Sources" / "Services"
            / "AppPreferences.swift").read_text(encoding="utf-8")
    named = re.search(r'testSuiteName\s*=\s*"([^"]+)"', home)
    assert named, "AppPreferences no longer names the suite the tests get"
    suite = named.group(1)
    assert suite.strip(), "the test suite name is blank"

    project = (REPO / "PostRollApp" / "project.yml").read_text(encoding="utf-8")
    bundles = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", project)
    assert bundles, "no bundle identifiers in project.yml to compare against"
    assert suite not in bundles, (
        f"the tests' scratch suite is {suite}, which is one of this project's "
        f"own bundle identifiers ({', '.join(bundles)}), so it is not a scratch "
        "suite at all")


def _scratch_opener(code: str) -> str:
    """The body of the function AppPreferences opens a scratch suite with."""
    found = re.search(
        r"static func openScratchSuite\([^)]*\)\s*->\s*UserDefaults\s*\{(.*?)\n    \}",
        code, re.S)
    assert found, (
        "AppPreferences no longer has openScratchSuite, so nothing names the "
        "one place a scratch preferences suite is opened")
    return found.group(1)


def test_the_scratch_suite_is_emptied_when_it_is_opened():
    """A value one run left behind must not be an input to the next (#744).

    Every other scratch suite in the Swift tests deletes itself in teardown.
    This one is opened once per process and shared by the whole run, so the
    clearing belongs where the suite is opened rather than in a teardown block
    per test, which would take the value away from tests that deliberately
    share it within a run.

    Checked here rather than in Swift because `AppPreferences.store` is a
    `static let`: nothing inside a run can watch the real suite being opened.
    What Swift proves is that opening one empties it
    (`ScratchPreferencesTests`); what this proves is that the store the whole
    test bundle reads is opened that way.
    """
    home = (REPO / "PostRollApp" / "Sources" / "Services"
            / "AppPreferences.swift").read_text(encoding="utf-8")
    code = swift_as_the_test_bundle_sees_it(swift_code_only(home))

    body = _scratch_opener(code)
    assert "removePersistentDomain" in body, (
        "openScratchSuite does not clear the domain it opens, so whatever a "
        "test wrote stays in that suite's plist and is an input to the next "
        "run of the suite, which is diagnosed as a flaky test rather than as "
        "leftover state (#744)")
    assert body.index("removePersistentDomain") < body.index("UserDefaults(suiteName:"), (
        "openScratchSuite clears the domain after opening it, so the instance "
        "it hands out can still be holding the values it just deleted")

    assert re.search(r"static let store[^\n]*openScratchSuite", code), (
        "AppPreferences.store no longer goes through openScratchSuite, so the "
        "clearing above is not on the path the test bundle actually reads")


def test_the_scan_can_still_see_a_suite_opened_without_clearing_it():
    # The control, and the shape that shipped: the opener as it stood before
    # #744, which a rule that had stopped matching would report as clean (L98).
    before = (
        "    static func openScratchSuite(named name: String) -> UserDefaults {\n"
        "        guard let scratch = UserDefaults(suiteName: name) else {\n"
        "            fatalError(\"no\")\n"
        "        }\n"
        "        return scratch\n"
        "    }\n")
    assert "removePersistentDomain" not in _scratch_opener(before)


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


def test_the_scan_can_still_see_the_live_preferences_as_a_default():
    # The other half of what a live location is (#727). Written as both
    # spellings, because the one that actually shipped was the inferred `.standard`
    # and a rule reading only the qualified form would have passed it.
    spelled = swift_as_the_test_bundle_sees_it(swift_code_only(
        "final class Store {\n"
        "    init(defaults: UserDefaults = UserDefaults.standard) {}\n}\n"))
    assert _hits(LIVE_DEFAULT, spelled) == [2]
    inferred = swift_as_the_test_bundle_sees_it(swift_code_only(
        "final class Store {\n    init(defaults: UserDefaults = .standard) {}\n}\n"))
    assert _hits(LIVE_DEFAULT, inferred) == [2]


def test_a_live_default_the_app_alone_compiles_is_not_an_offence():
    # The other direction. A control that only ever proves the guard FIRES will
    # accept one that fires on everything, and this arrangement is exactly what
    # the fix relies on (L104).
    allowed = swift_as_the_test_bundle_sees_it(swift_code_only(
        "final class Thing {\n#if !POSTROLL_TESTS\n"
        "    convenience init() { self.init(fileURL: AppPaths.analyticsFile) }\n"
        "#endif\n}\n"))
    assert _hits(LIVE_DEFAULT, allowed) == []


def test_the_scan_can_still_see_the_live_preferences_named_inline():
    """Both spellings, and the inferred one is the one that shipped."""
    spelled = swift_as_the_test_bundle_sees_it(swift_code_only(
        "    func save() { UserDefaults.standard.set(tags, forKey: key) }\n"))
    assert _hits(LIVE_PREFERENCES, spelled) == [1]
    inferred = swift_as_the_test_bundle_sees_it(swift_code_only(
        "    private init() { defaults = .standard }\n"))
    assert _hits(LIVE_PREFERENCES, inferred) == [1]


def test_a_scratch_suite_is_not_the_live_preferences():
    # The other direction. A control that only proves the rule FIRES will accept
    # one that fires on everything, and the arrangement the fix relies on is a
    # store built from a suite name (L104).
    allowed = swift_as_the_test_bundle_sees_it(swift_code_only(
        '    static let store = UserDefaults(suiteName: "postroll.tests")\n'))
    assert _hits(LIVE_PREFERENCES, allowed) == []


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


def test_the_scan_can_still_see_a_live_singleton():
    # The shape that shipped, written out as it stood before #945 (L98).
    offender = swift_as_the_test_bundle_sees_it(swift_code_only(
        "final class Book {\n"
        "    static let shared = Book(fileURL: AppPaths.accountsFile)\n}\n"))
    assert _hits(LIVE_SINGLETON, offender) == [2]


def test_a_live_singleton_the_app_alone_compiles_is_not_an_offence():
    # The other direction, and the arrangement the fix relies on: the app keeps
    # its own live instance, compiled out of the test bundle. A control that
    # only ever proves a guard FIRES will accept one that fires on everything
    # (L104).
    allowed = swift_as_the_test_bundle_sees_it(swift_code_only(
        "final class Book {\n#if POSTROLL_TESTS\n"
        "    static let shared = Book(fileURL: scratchAccountsFile())\n"
        "#else\n"
        "    static let shared = Book(fileURL: AppPaths.accountsFile)\n"
        "#endif\n}\n"))
    assert _hits(LIVE_SINGLETON, allowed) == []


def test_the_scan_does_not_fire_on_a_type_named_under_AppPaths():
    # `DataInventory` builds an `AppPaths.Layout` on a root of its own, which
    # reaches no file at all. A guard that fires on the code it exists to
    # permit is one that gets turned off (L104).
    innocent = swift_as_the_test_bundle_sees_it(swift_code_only(
        "    private static let layout = AppPaths.Layout("
        "root: URL(fileURLWithPath: \"/\"))\n"))
    assert _hits(LIVE_SINGLETON, innocent) == []


def test_the_app_still_has_an_account_book_of_its_own():
    # The other half, on the same reasoning as the analytics one: a rule that
    # only ever checks an ABSENCE is satisfied by deleting both branches, and
    # then the shipping app has no account book at all (L159).
    book = swift_code_only(
        (SOURCES / "Services" / "AccountBook.swift").read_text(encoding="utf-8"))
    assert "AppPaths.accountsFile" in book, (
        "AccountBook no longer names the live accounts file anywhere, so the "
        "shipping app has no follower counts to read")
    assert "AppPaths.accountsFile" not in swift_as_the_test_bundle_sees_it(book), (
        "the live accounts file is named in code the test bundle compiles")
