"""The test-target hygiene guards, off the app build (#1089, #45, #224, #384).

Every rule here reads source text and nothing else, so paying an app build to
re-prove one bought nothing. `TestTargetHygieneTests` held seven registry
entries at about 29 seconds each; they run here in well under a second between
them.

Each matcher is asked directly what it can see, in both directions, before the
sweep that uses it. That is not decoration: the tree is clean, so a matcher that
sees one spelling and a matcher that sees three give the same silent pass over
the real files, and two of these have already narrowed once in Swift and were
caught by `check_guards` rather than by the codebase (L1, L48, L159).
"""

from __future__ import annotations

import pytest

from source_text import swift_without_string_literals
from swift_target_hygiene import (
    MANIFEST,
    PBXPROJ,
    TESTS_DIR,
    TEST_ONLY_FLAG,
    TESTABLE_IMPORT,
    UI_TESTS,
    APP,
    launches,
    offenders,
    on_disk_names,
    registered_names,
    seam_is_behind_the_test_only_flag,
    seam_signature,
    seam_uses,
    shipping_app_state_lines,
    suite_names,
    definitions_of_the_test_only_flag,
)

#: Below this, a sweep has stopped reading the tree and its silence means
#: nothing. The suite holds close to three hundred files; fifty is far enough
#: below that a real deletion does not trip it and far enough above zero that a
#: scanner reading nothing cannot pass (L98).
A_REAL_SWEEP = 50


@pytest.fixture(scope="module")
def project() -> str:
    """The generated project, or a failure naming what is wrong.

    Deliberately NOT a skip. A conditional skip in a guard is the silent-pass
    problem: the suite reports green while the check never ran, and the one run
    where this skips is also the one run where something else here goes
    inexplicably red.
    """
    assert PBXPROJ.exists(), (
        f"project.pbxproj is not at {PBXPROJ}. Every hygiene guard below asks "
        f"it what the bundle contains, so this is a failure rather than a skip."
    )
    return PBXPROJ.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def registered(project: str) -> set[str]:
    names = registered_names(project)
    assert len(names) > A_REAL_SWEEP, (
        "the project lists almost no Swift files, so every guard below is vacuous"
    )
    return names


@pytest.fixture(scope="module")
def app_state_source() -> str:
    return (APP / "Sources" / "AppState.swift").read_text(encoding="utf-8")


# ── no test imports the app module (#45) ─────────────────────────────────────
#
# PostRollTests has NO dependency on the PostRoll app target: it compiles a
# curated list of Sources files directly into the bundle (see project.yml) so
# tests can never touch live data and run without the GUI. A testable import
# therefore resolves to nothing under the standalone scheme (a clean-build
# failure) and to a STALE module under the main scheme, which surfaces as a
# baffling "Type X has no member Y" for a member that was just added.

def test_the_import_scan_sees_the_import(tmp_path):
    """The must-catch half, since the tree is clean and cannot show it."""
    (tmp_path / "Offender.swift").write_text(f"{TESTABLE_IMPORT}\nfinal class A {{}}\n")
    scan = offenders(tmp_path, {"Offender.swift"}, containing=TESTABLE_IMPORT)
    assert scan.offenders == ["Offender.swift"]
    assert scan.read == 1


def test_the_import_scan_leaves_an_ordinary_import_alone(tmp_path):
    (tmp_path / "Fine.swift").write_text("import XCTest\nfinal class A {}\n")
    scan = offenders(tmp_path, {"Fine.swift"}, containing=TESTABLE_IMPORT)
    assert scan.offenders == []
    assert scan.read == 1, "a clean file must still count as read"


def test_a_stray_file_the_project_does_not_compile_cannot_fail_the_guard(tmp_path):
    """The flake that produced #224: something else writing into the directory.

    A file the bundle does not compile cannot break the bundle, so the scan is
    handed the project's own list rather than whatever is on disk.
    """
    (tmp_path / "Real.swift").write_text("import XCTest\n")
    (tmp_path / "Scratch.swift.bak.swift").write_text(TESTABLE_IMPORT)
    assert offenders(tmp_path, {"Real.swift"}, containing=TESTABLE_IMPORT).offenders == []


def test_a_file_that_disappears_mid_run_is_not_an_offender(tmp_path):
    """Registered but unreadable right now.

    Absence is not evidence of the forbidden import, and guessing either way is
    worse than saying no.
    """
    scan = offenders(tmp_path, {"Vanished.swift"}, containing=TESTABLE_IMPORT)
    assert scan.offenders == []
    assert scan.read == 0, (
        "the scan opened nothing, and that must be visible to the caller rather "
        "than presented as a clean sweep (L10, L98)")


def test_the_project_reader_takes_file_names_out_of_the_generated_project():
    pbxproj = """
    /* Begin PBXBuildFile section */
    A1 /* AudioPreviewPlayerTests.swift in Sources */ = {isa = PBXBuildFile; };
    A2 /* Layout_Sidecar-Tests.swift in Sources */ = {isa = PBXBuildFile; };
    /* End PBXBuildFile section */
    """
    assert registered_names(pbxproj) == {
        "AudioPreviewPlayerTests.swift", "Layout_Sidecar-Tests.swift"}


def test_an_empty_project_yields_no_names_rather_than_everything():
    """The failure direction that matters.

    An unparsed project must not silently mean "check nothing", which is why
    every sweep here also asserts a floor on the count (L98).
    """
    assert registered_names("") == set()


def test_the_import_scan_honours_its_exclusion(tmp_path):
    """The guard's own file names the needle, so it must be able to stand aside."""
    (tmp_path / "Guard.swift").write_text(f"let forbidden = \"{TESTABLE_IMPORT}\"\n")
    assert offenders(tmp_path, {"Guard.swift"}, containing=TESTABLE_IMPORT,
                     excluding="Guard.swift").offenders == []


def test_no_test_imports_the_app_module(registered: set[str]):
    scan = offenders(TESTS_DIR, registered, containing=TESTABLE_IMPORT)
    # No offenders is what a scan that opened NOTHING reports too, and the
    # project-file floor above cannot see that: it proves the project parsed,
    # not that a single test source was read (L98).
    assert scan.read > A_REAL_SWEEP, (
        f"the import scan opened only {scan.read} test files, so its silence "
        "means nothing"
    )
    found = scan.offenders
    assert not found, (
        "PostRollTests is a self-contained bundle with no PostRoll app dependency, "
        "so a testable import of the app module breaks the build (stale or missing "
        f"module). Remove it from: {', '.join(found)}. The types under test are "
        "compiled into the bundle directly via project.yml: reference them without "
        "an import."
    )


# ── every test file on disk is in the generated project (#45) ────────────────
#
# xcodegen resolves the Tests source glob at project-generation time, not build
# time, so a newly added test file compiles and runs only after `xcodegen
# generate`. Until then the suite passes while silently skipping it. This is the
# guard that MUST read the live directory: on disk but not in the project is
# precisely what it looks for.

def test_the_orphan_scan_sees_a_file_the_project_does_not_name(tmp_path):
    (tmp_path / "Orphan.swift").write_text("final class Orphan {}\n")
    (tmp_path / "Known.swift").write_text("final class Known {}\n")
    project = "path = Known.swift; sourceTree = <group>;"
    assert sorted(n for n in on_disk_names(tmp_path) if n not in project) \
        == ["Orphan.swift"]


def test_every_test_source_file_is_in_the_generated_project(project: str):
    on_disk = on_disk_names(TESTS_DIR)
    assert len(on_disk) > A_REAL_SWEEP, (
        "the scan found almost no test files on disk, so it has stopped working"
    )
    orphans = sorted(name for name in on_disk if name not in project)
    assert not orphans, (
        "These test files exist on disk but are not in the generated Xcode project, "
        "so they compile and run only after regeneration (the suite silently skips "
        f"them): {', '.join(orphans)}. Run `xcodegen generate` after adding a test file."
    )


# ── one suite per file (#384) ────────────────────────────────────────────────
#
# A file holding two suites reads as one: tests appended at what looks like the
# end of it land in the second, and `-only-testing:PostRollTests/SomeTests` then
# executes none of them and reports success. That happened on 2026-08-12 while
# proving a new guard could fail: the deliberate break was in place, the
# targeted run came back green, and the tests it was meant to run were sitting
# in a class the invocation never named. A run that executes none of what you
# meant is indistinguishable from one that passed (L98).

def test_the_suite_scanner_sees_every_spelling():
    source = """
        final class PlainTests: XCTestCase {}
        class WithoutFinalTests : XCTestCase {
        }
        final class SpacedTests:XCTestCase {}
        """
    assert suite_names(source) == ["PlainTests", "WithoutFinalTests", "SpacedTests"]


def test_the_suite_scanner_is_not_answered_by_a_comment():
    source = """
        // final class CommentedTests: XCTestCase {}
        /// final class DocumentedTests: XCTestCase {}
        * final class ContinuedTests: XCTestCase {}
        final class RealTests: XCTestCase {}
        """
    assert suite_names(source) == ["RealTests"]


def test_the_suite_scanner_leaves_a_plain_class_alone():
    assert suite_names("final class Helper: NSObject {}\nenum Thing {}\n") == []


def test_a_suite_inside_a_string_literal_is_not_a_suite():
    """A test that keeps a Swift snippet as another guard's FIXTURE declares
    no suite. Counting one there reports a file as holding two when it holds
    one, and sends the reader to split a file that is already fine (L104)."""
    source = "\n".join([
        "func testTheScannerIgnoresThis() {",
        "    let fixture = " + '"""',
        "    final class SomeTests: XCTestCase {}",
        "    " + '"""',
        "}",
        "final class RealTests: XCTestCase {}",
    ])

    assert suite_names(swift_without_string_literals(source)) == ["RealTests"]


def test_each_test_file_holds_exactly_one_suite(registered: set[str]):
    doubled: list[str] = []
    suites_seen = 0
    for name in sorted(registered):
        path = TESTS_DIR / name
        if not path.exists():
            continue
        # String literals blanked as well as comments (#1230's shape one step
        # along). A test that keeps a Swift snippet in a multiline literal as
        # another guard's fixture declares no suite, and counting one there
        # reports a file as holding two when it holds one (L104).
        found = suite_names(swift_without_string_literals(
            path.read_text(encoding="utf-8")))
        suites_seen += len(found)
        if len(found) > 1:
            doubled.append(f"{name}: {', '.join(found)}")

    # Finding no suites at all would pass the assertion below while proving
    # nothing, which is the failure mode this guard is about (L98).
    assert suites_seen > A_REAL_SWEEP, (
        "the scanner found almost no test suites, so it has stopped working"
    )
    assert not doubled, (
        "These files hold more than one test suite. Tests added at what looks like "
        "the end of the file land in the last one, and a targeted run of the first "
        "reports success having run none of them. Move each extra suite into its "
        "own file named after it:\n\n" + "\n".join(doubled)
    )


# ── the AppState test seam stays out of the shipping app (#45) ───────────────
#
# `AppState(events:)` builds an event list without reading the store, so a test
# can never see or rewrite the real events.json. It must stay out of the
# shipping app: an accidental call there would not look like an accident, it
# would open the app on an empty library while the real events sat untouched on
# disk. The build enforces this (the initialiser is compiled behind the
# test-only flag, which only the test target sets); this guards the enforcement,
# because deleting the `#if` would silently hand the seam back to the app and
# nothing else would go red.

def test_the_flag_scan_sees_a_seam_outside_the_flag():
    assert seam_is_behind_the_test_only_flag(
        f"#if {TEST_ONLY_FLAG}\nlet x = 1\n#endif\ninit(events: [Event]) {{}}\n"
    ) is False


def test_the_flag_scan_sees_a_seam_inside_the_flag():
    assert seam_is_behind_the_test_only_flag(
        f"#if {TEST_ONLY_FLAG}\ninit(events: [Event]) {{}}\n#endif\n"
    ) is True


def test_the_flag_scan_says_so_when_the_seam_is_gone():
    """Gone entirely is fine, and must be told apart from gone from the flag.

    Returning False for an absent seam would make the guard fail on a file that
    has no seam to protect, and the message would name a cause that did not
    happen (L11).
    """
    assert seam_is_behind_the_test_only_flag("struct AppState {}\n") is None


def test_the_app_state_test_seam_stays_out_of_the_shipping_app(app_state_source: str):
    behind = seam_is_behind_the_test_only_flag(app_state_source)
    if behind is None:
        # Gone entirely is fine: the thing guarded is that it is never
        # reachable from the app, not that it exists.
        return
    assert behind, (
        f"AppState's `init(events:` seam is not inside a `#if {TEST_ONLY_FLAG}` block, "
        "so the shipping app can call it. That would start the app on an empty event "
        "list while the real events.json sat untouched on disk. Put it back behind "
        "the flag."
    )


# ── the seam says where it points (#684) ─────────────────────────────────────
#
# Both locations used to carry a default naming the LIVE ones, so a test that
# left them out was handed the real events.json and the real media tree while
# its call still read as the safe constructor. Seven call sites were in exactly
# that state. A parameter a function needs in order to be CORRECT must not carry
# a default standing for absent (L168).

def test_the_signature_reader_sees_a_default():
    assert "=" in (seam_signature(
        "init(events: [Event],\n storeURL: URL = EventStore.storeURL,\n"
        " dataRoot: URL) {\n") or "")


def test_the_signature_reader_leaves_a_required_signature_alone():
    assert "=" not in (seam_signature(
        "init(events: [Event],\n storeURL: URL,\n dataRoot: URL) {\n") or "")


def test_the_signature_reader_stops_at_the_signature():
    """It must not read on into the body, where an `=` is ordinary code."""
    signature = seam_signature(
        "init(events: [Event],\n storeURL: URL,\n dataRoot: URL) {\n"
        "    let total = events.count\n}\n")
    assert signature is not None and "total" not in signature


def test_the_app_state_test_seam_says_where_it_points(app_state_source: str):
    signature = seam_signature(app_state_source)
    if signature is None:
        # Gone entirely is fine, for the same reason as above.
        return
    assert signature, (
        "AppState's `init(events:` seam has no signature this can read, so "
        "nothing below checked anything"
    )
    # Without this the assertion below is answered by any parse that came back
    # empty, and empty is what a scanner that stopped working returns (L98).
    for parameter in ("storeURL", "dataRoot"):
        assert parameter in signature, (
            f"the seam's signature no longer names {parameter}, so this guard is "
            f"reading something other than the seam: {signature}"
        )
    assert "=" not in signature, (
        f"AppState's `init(events:` seam carries a default value: {signature}. Both "
        "storeURL and dataRoot must be required. A default here is the LIVE "
        "events.json and the LIVE media tree, handed to any test that leaves it out, "
        "and the launch sweeps delete media for every event not in the list they "
        "hold. Take the default off and make each call site say where it points."
    )


# ── the test-only flag is defined once, on the test target (#853) ────────────
#
# If the test target stops defining it, every test using the seam fails to
# compile, which is loud. If the APP target ever starts defining it, the seam
# quietly becomes reachable again, which is not.

def test_a_second_definition_is_still_caught():
    """The half that must not be lost.

    Without it, dropping comment lines could be dropping everything and the
    guard below would pass on any manifest at all, which is the failure it
    exists to prevent.
    """
    manifest = f"""
targets:
  PostRoll:
    settings:
      base:
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: {TEST_ONLY_FLAG}
  PostRollTests:
    settings:
      base:
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: {TEST_ONLY_FLAG}
"""
    assert definitions_of_the_test_only_flag(manifest) == 2, (
        "the app target defines the test-only flag and this counted it as one "
        "definition, so every test-only seam is reachable from the shipping app "
        "and nothing says so"
    )


def test_a_comment_naming_the_flag_is_not_a_definition():
    """The case that cost a CI round trip (#853).

    The GUI target added in #849 carried a comment saying it deliberately does
    not set the flag, and the guard reported two definitions and blamed the app
    target, which had done nothing.
    """
    manifest = f"""
targets:
  PostRoll:
    settings:
      base:
        # Deliberately does not set {TEST_ONLY_FLAG}, because the
        # seams behind it must not be reachable from the shipping app.
        SWIFT_VERSION: "6.0"
  PostRollTests:
    settings:
      base:
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: {TEST_ONLY_FLAG}
"""
    assert definitions_of_the_test_only_flag(manifest) == 1, (
        "a comment explaining the flag was counted as a definition, so the manifest "
        "cannot be commented without failing a guard about something the comment "
        "did not do"
    )


def test_only_the_test_target_defines_the_test_only_flag():
    manifest = MANIFEST.read_text(encoding="utf-8")
    definitions = definitions_of_the_test_only_flag(manifest)
    assert definitions == 1, (
        f"{TEST_ONLY_FLAG} must be defined once, on the PostRollTests target only. "
        f"Found {definitions} definitions in project.yml. Defining it on the app "
        "target would make every test-only seam reachable from the shipping app."
    )


# ── no test builds an AppState the shipping way (#681) ───────────────────────
#
# The seam is worth nothing while the unsafe path is one character shorter to
# type. The shipping initialiser calls `loadStore()`, which reads the real
# events.json and then runs every launch sweep against whatever came back, and
# those sweeps delete media for events NOT in the list they are handed. A test
# that only wants somewhere for a reading to land gets all of that, against live
# data, for free. Tests must be structurally unable to reach the real store (L2).

def test_the_shipping_construction_scan_sees_every_spelling():
    source = "let a = AppState()\nlet b = AppState( )\nlet c = AppState(\n)\n"
    assert shipping_app_state_lines(source) == [1, 2]


def test_the_shipping_construction_scan_is_not_answered_by_a_comment():
    source = "// let a = AppState()\n/// AppState() is forbidden\nlet b = AppState()\n"
    assert shipping_app_state_lines(source) == [3]


def test_the_shipping_construction_scan_leaves_the_seam_alone():
    assert shipping_app_state_lines(
        "let a = AppState(events: [], storeURL: url, dataRoot: root)\n") == []


def test_the_seam_counter_counts_the_seam():
    assert seam_uses("AppState(events: [])\nAppState(events: [x])\nAppState()\n") == 2


def test_no_test_builds_an_app_state_through_the_shipping_initialiser(
        registered: set[str]):
    found: list[str] = []
    scanned = 0
    uses = 0
    for name in sorted(registered):
        path = TESTS_DIR / name
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        scanned += 1
        uses += seam_uses(text)
        found += [f"{name}:{line}" for line in shipping_app_state_lines(text)]

    # Both controls are here because "no offenders" is what a scanner that read
    # nothing also reports (L98).
    assert scanned > A_REAL_SWEEP, (
        "the scanner opened almost no test files, so it has stopped working"
    )
    assert uses > 10, (
        "the scanner found almost no AppState construction of any kind, so it is "
        "reading something other than the test sources"
    )
    assert not found, (
        "These tests build an AppState through the shipping initialiser, which reads "
        "the real events.json and runs the launch sweeps that delete media for every "
        "event not in the list they read:\n\n" + "\n".join(found) + "\n\nUse the test "
        "seam instead, pointed at a temporary tree:\n\n"
        "    AppState(events: [], storeURL: <temp>/events.json, dataRoot: <temp>)"
    )


# ── the GUI target launches the app once (#864) ──────────────────────────────
#
# Measured on the runner on 2026-08-23: 43.6 seconds for the first GUI test and
# 41.1 for the second, of the SAME binary built by the same job. The cost is per
# LAUNCH, not per build, so it is paid again for every test that starts its own
# app, and the job grows in 42 second steps while the amount of real testing
# does not.
#
# Read from the UI target's source, which is not compiled into the unit bundle:
# a UI test bundle and a unit test bundle cannot be loaded together, so text was
# all the Swift version could have either.

def test_the_launch_counter_counts_a_launch():
    assert launches("Self.shared = Result { try LaunchedApp.launch(dataRoot: r) }\n") == 1


def test_the_launch_counter_is_not_answered_by_a_comment():
    assert launches("// LaunchedApp.launch(dataRoot: r)\n/// LaunchedApp.launch(x)\n") == 0


def test_the_gui_target_launches_the_app_once():
    count = launches(UI_TESTS.read_text(encoding="utf-8"))
    assert count == 1, (
        f"AppEntryPointUITests starts the app {count} times. Each one costs about 42 "
        "seconds on the runner and the testing in it costs almost nothing, so this is "
        "the whole price of the GUI job. Zero means this guard is reading nothing at "
        "all and would pass on any file (#864)."
    )
