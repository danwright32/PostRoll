import XCTest

/// How the hygiene guards decide which files they are talking about (#224).
///
/// The import guard used to enumerate `Tests/` at run time and grep whatever it
/// found. That made it sensitive to anything else touching the directory while
/// it ran, and it went red once during other tooling activity and never
/// reproduced. A guard that can fail for a reason unrelated to the thing it
/// guards gets ignored, which is exactly what makes it useless later.
///
/// So the two guards now ask different questions of different sources, on
/// purpose:
///
/// * the import guard considers only files the GENERATED PROJECT compiles, so a
///   stray or half-written file in the directory cannot fail it;
/// * the orphan guard is the one that looks at the directory, because "on disk
///   but not in the project" is the whole thing it exists to find.
enum TestSourceInventory {

    /// The Swift file names the generated project compiles.
    ///
    /// Read out of project.pbxproj rather than assumed, because that file IS
    /// the answer to "what does this bundle contain".
    static func registeredNames(inProject pbxproj: String) -> Set<String> {
        var names: Set<String> = []
        var scanner = Substring(pbxproj)
        while let range = scanner.range(of: #"[A-Za-z0-9_+\-]+\.swift"#, options: .regularExpression) {
            names.insert(String(scanner[range]))
            scanner = scanner[range.upperBound...]
        }
        return names
    }

    /// The `.swift` files actually sitting in a directory.
    static func onDiskNames(in dir: URL) throws -> Set<String> {
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return Set(entries.filter { $0.pathExtension == "swift" }.map(\.lastPathComponent))
    }

    /// The XCTestCase subclasses declared in one file's source.
    ///
    /// Comment lines are stripped first, so a guard cannot be satisfied (or
    /// failed) by prose ABOUT a class rather than the declaration itself: a
    /// check that is green on a comment is indistinguishable from one that
    /// works (L103).
    static func suiteNames(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") }
            .compactMap { line in
                guard let range = line.range(
                    of: #"^(final )?class ([A-Za-z0-9_]+)\s*:\s*XCTestCase"#,
                    options: .regularExpression) else { return nil }
                return line[range]
                    .replacingOccurrences(of: "final ", with: "")
                    .replacingOccurrences(of: "class ", with: "")
                    .split(separator: ":").first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
    }

    /// The line numbers where a source builds an AppState through the SHIPPING
    /// initialiser, the one that reads the real events.json and runs the launch
    /// sweeps.
    ///
    /// Comment lines are stripped first, so prose about the initialiser is not
    /// an offender (L103). Spelled as a regular expression rather than a plain
    /// needle so this file is not itself caught: the pattern's own text carries
    /// backslashes and therefore does not match the pattern.
    static func shippingAppStateLines(in source: String) -> [Int] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .enumerated()
            .filter { !$0.element.hasPrefix("//") && !$0.element.hasPrefix("*") }
            .filter {
                $0.element.range(of: #"\bAppState\(\s*\)"#, options: .regularExpression) != nil
            }
            .map { $0.offset + 1 }
    }

    /// How many times a source reaches for the test seam.
    ///
    /// Only used as a positive control: a scanner that finds no construction at
    /// all would report every file clean, and clean is indistinguishable from
    /// blind (L98).
    static func seamUses(in source: String) -> Int {
        source.components(separatedBy: "AppState(events:").count - 1
    }

    /// Files carrying `needle`, considering only ones the project compiles.
    static func offenders(in dir: URL, registered: Set<String>, containing needle: String,
                          excluding: String) -> [String] {
        registered.subtracting([excluding]).sorted().filter { name in
            let url = dir.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return contents.contains(needle)
        }
    }
}

/// Guards the self-contained `PostRollTests` bundle.
///
/// `PostRollTests` has NO dependency on the PostRoll app target — it compiles a
/// curated list of `Sources/*` files directly into the test bundle (see
/// project.yml) so tests can never touch live data and run without the GUI. A
/// `@testable import PostRoll` therefore resolves to nothing under the
/// standalone `PostRollTests` scheme (clean-build failure) and to a STALE module
/// under the main scheme — which surfaces as a baffling "Type X has no member Y"
/// for a member that was just added. This test fails loudly and immediately
/// instead, pointing the next test author at the real cause. See issue #45.
final class TestTargetHygieneTests: XCTestCase {

    private var testsDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private var pbxprojURL: URL {
        testsDir.deletingLastPathComponent()
            .appendingPathComponent("PostRoll.xcodeproj/project.pbxproj")
    }

    /// The generated project, or a failure naming what is wrong.
    ///
    /// Deliberately NOT a skip. A conditional skip in a guard is the silent-pass
    /// problem #106 fixed on the Python side: the suite reports green while the
    /// check never ran, and the one run where this skipped is also the one run
    /// where something else in here went inexplicably red.
    private func generatedProject() throws -> String {
        do {
            return try String(contentsOf: pbxprojURL, encoding: .utf8)
        } catch {
            XCTFail("project.pbxproj could not be read at \(pbxprojURL.path): "
                    + "\(error.localizedDescription). Every hygiene guard below asks it "
                    + "what the bundle contains, so this is a failure rather than a skip.")
            throw error
        }
    }

    func testNoTestableImportOfAppModule() throws {
        // Build the needle from parts so this guard file doesn't match itself.
        let forbidden = "@testable import " + "PostRoll"
        let registered = TestSourceInventory.registeredNames(inProject: try generatedProject())
        XCTAssertGreaterThan(registered.count, 50,
                             "the project lists almost no Swift files, so this guard is vacuous")

        let offenders = TestSourceInventory.offenders(
            in: testsDir, registered: registered, containing: forbidden,
            excluding: URL(fileURLWithPath: #filePath).lastPathComponent)

        XCTAssertTrue(
            offenders.isEmpty,
            "PostRollTests is a self-contained bundle with no PostRoll app dependency, "
            + "so a testable import of the app module breaks the build (stale or missing "
            + "module). Remove it from: \(offenders.joined(separator: ", ")). The types under "
            + "test are compiled into the bundle directly via project.yml — reference them "
            + "without an import."
        )
    }

    /// xcodegen resolves the `Tests/` source glob at project-generation time, not
    /// build time, so a newly added test file compiles and runs only after
    /// `xcodegen generate`. Until then the suite passes while silently skipping
    /// it — the same "looks wired but isn't" trap as the import above. This fails
    /// if any test source on disk is missing from the generated project.
    ///
    /// This is the guard that MUST read the live directory: on disk but not in
    /// the project is precisely what it looks for.
    func testEveryTestSourceFileIsInTheGeneratedProject() throws {
        let project = try generatedProject()
        let orphans = try TestSourceInventory.onDiskNames(in: testsDir)
            .filter { !project.contains($0) }
            .sorted()

        XCTAssertTrue(
            orphans.isEmpty,
            "These test files exist on disk but aren't in the generated Xcode project, so "
            + "they compile and run only after regeneration (the suite silently skips them): "
            + "\(orphans.joined(separator: ", ")). Run `xcodegen generate` after adding a test file."
        )
    }

    /// One suite per file, so `-only-testing:PostRollTests/SomeTests` runs what
    /// its name says (#384).
    ///
    /// A file holding two suites reads as one: tests appended at what looks like
    /// the end of it land in the second, and a targeted run of the first then
    /// executes none of them and reports success. That happened on 2026-08-12
    /// while proving a new guard could fail: the deliberate break was in place,
    /// the targeted run came back green, and the tests it was meant to run were
    /// sitting in a class the invocation never named. A run that executes none
    /// of what you meant is indistinguishable from one that passed (L98).
    ///
    /// Reads the files the generated project compiles, so a half-written file in
    /// the directory cannot fail it.
    func testEachTestFileHoldsExactlyOneSuite() throws {
        let registered = TestSourceInventory.registeredNames(inProject: try generatedProject())
        XCTAssertGreaterThan(registered.count, 50,
                             "the project lists almost no Swift files, so this guard is vacuous")

        var offenders: [String] = []
        var suitesSeen = 0
        for name in registered.sorted() {
            let url = testsDir.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let suites = TestSourceInventory.suiteNames(in: contents)
            suitesSeen += suites.count
            if suites.count > 1 {
                offenders.append("\(name): \(suites.joined(separator: ", "))")
            }
        }

        // Finding no suites at all would pass the assertion below while proving
        // nothing, which is the failure mode this guard is about (L98).
        XCTAssertGreaterThan(suitesSeen, 50,
                             "the scanner found almost no test suites, so it has stopped working")
        XCTAssertTrue(offenders.isEmpty, """
            These files hold more than one test suite. Tests added at what looks \
            like the end of the file land in the last one, and a targeted run of \
            the first reports success having run none of them.

            Move each extra suite into its own file named after it:

            \(offenders.joined(separator: "\n"))
            """)
    }

    /// `AppState(events:)` builds an event list without reading the store, so a
    /// test can never see or rewrite the real events.json. It must stay out of
    /// the shipping app: an accidental call there would not look like an
    /// accident, it would open the app on an empty library while the real
    /// events sat untouched on disk.
    ///
    /// The build enforces this (the initialiser is compiled behind
    /// POSTROLL_TESTS, which only the test target sets), and this test guards
    /// the enforcement itself, because deleting the `#if` would silently hand
    /// the seam back to the app and nothing else would go red.
    func testTheAppStateTestSeamStaysOutOfTheShippingApp() throws {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // PostRollApp
        let source = try String(
            contentsOf: appDir.appendingPathComponent("Sources/AppState.swift"),
            encoding: .utf8)

        // Matched on the PREFIX, not the whole signature. This guard used to look
        // for `init(events: [Event])` exactly, and on 2026-08-13 the seam gained a
        // storeURL parameter (#446). The exact match then found nothing, took the
        // early return below, and passed while checking nothing at all: it would
        // have stayed green with the seam moved out of the flag entirely. Caught
        // by `tools/check_guards.py`, which reported it as SURVIVED (L103).
        let seam = "init(events:"
        guard let seamRange = source.range(of: seam) else {
            // Gone entirely is fine: the thing being guarded is that it is
            // never reachable from the app, not that it exists.
            return
        }

        let before = source[source.startIndex..<seamRange.lowerBound]
        let opens = before.components(separatedBy: "#if POSTROLL_TESTS").count - 1
        let closes = before.components(separatedBy: "#endif").count - 1

        XCTAssertGreaterThan(
            opens, closes,
            "AppState's `\(seam)` seam is not inside a `#if POSTROLL_TESTS` block, so the "
            + "shipping app can call it. That would start the app on an empty event list "
            + "while the real events.json sat untouched on disk. Put it back behind the flag."
        )
    }

    /// How many times the manifest DEFINES the test-only flag.
    ///
    /// Comment lines are dropped before counting, because a comment cannot
    /// define a build setting: counting one is a false accusation, and the
    /// message it produces names a cause that did not happen (#853, L11). This
    /// is what `tests/test_swift_test_target_covers_sources.py` already does to
    /// the same file, for the same reason spelled out there: a guard that can be
    /// answered by prose is not measuring what it claims to (L103).
    ///
    /// Dropping them is not a loosening. A commented out definition sets
    /// nothing, so not counting it is the correct answer, and a real definition
    /// on the app target is still caught wherever in the file it appears.
    ///
    /// Takes the manifest as text rather than reading the file, so the two cases
    /// below can be driven with a manifest this test wrote. A guard that can
    /// only ever be run against the one file that currently satisfies it has no
    /// way to be shown failing (L1).
    static func testOnlyFlagDefinitions(in manifest: String) -> Int {
        let code = manifest
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        return code.components(separatedBy: Self.testOnlyFlag).count - 1
    }

    /// Spelled in pieces so this file does not itself contain the token. The
    /// guard counts occurrences in project.yml rather than here, so this is
    /// only tidiness; naming it once and building it once keeps the two cases
    /// below honest about what they are constructing.
    static let testOnlyFlag = "POSTROLL" + "_TESTS"

    /// The flag the guard above depends on is set in exactly one place. If the
    /// test target stops defining it, every test using the seam fails to
    /// compile, which is loud; if the APP target ever starts defining it, the
    /// seam quietly becomes reachable again, which is not.
    func testOnlyTheTestTargetDefinesTheTestOnlyFlag() throws {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: appDir.appendingPathComponent("project.yml"), encoding: .utf8)

        let definitions = Self.testOnlyFlagDefinitions(in: manifest)
        XCTAssertEqual(
            definitions, 1,
            "\(Self.testOnlyFlag) must be defined once, on the PostRollTests target only. "
            + "Found \(definitions) definitions in project.yml. Defining it on the app target "
            + "would make every test-only seam reachable from the shipping app."
        )
    }

    /// A second definition is still caught, wherever it is (#853).
    ///
    /// The half that must not be lost. Without this, dropping comments could be
    /// dropping everything and the guard above would pass on any manifest at
    /// all, which is the failure it exists to prevent.
    func testASecondDefinitionIsStillCaught() {
        let manifest = """
            targets:
              PostRoll:
                settings:
                  base:
                    SWIFT_ACTIVE_COMPILATION_CONDITIONS: \(Self.testOnlyFlag)
              PostRollTests:
                settings:
                  base:
                    SWIFT_ACTIVE_COMPILATION_CONDITIONS: \(Self.testOnlyFlag)
            """

        XCTAssertEqual(
            Self.testOnlyFlagDefinitions(in: manifest), 2,
            "the app target defines the test-only flag and this counted it as "
            + "one definition, so every test-only seam is reachable from the "
            + "shipping app and nothing says so")
    }

    /// A comment that merely NAMES the flag is not a definition (#853).
    ///
    /// This is the case that cost a CI round trip: the GUI target added in #849
    /// carried a comment saying it deliberately does not set the flag, and the
    /// guard reported two definitions and blamed the app target, which had done
    /// nothing.
    func testACommentNamingTheFlagIsNotADefinition() {
        let manifest = """
            targets:
              PostRoll:
                settings:
                  base:
                    # Deliberately does not set \(Self.testOnlyFlag), because the
                    # seams behind it must not be reachable from the shipping app.
                    SWIFT_VERSION: "6.0"
              PostRollTests:
                settings:
                  base:
                    SWIFT_ACTIVE_COMPILATION_CONDITIONS: \(Self.testOnlyFlag)
            """

        XCTAssertEqual(
            Self.testOnlyFlagDefinitions(in: manifest), 1,
            "a comment explaining the flag was counted as a definition, so the "
            + "manifest cannot be commented without failing a guard about "
            + "something the comment did not do")
    }

    /// No test builds an AppState through the shipping initialiser (#681).
    ///
    /// The seam above is worth nothing while the unsafe path is one character
    /// shorter to type. The shipping initialiser calls `loadStore()`, which
    /// reads the real events.json and then runs every launch sweep against
    /// whatever came back, and those sweeps delete media for events NOT in the
    /// list they are handed. A test that only wants somewhere for a reading to
    /// land gets all of that, against live data, for free.
    ///
    /// So the rule is structural rather than remembered: tests must be unable
    /// to reach the real store (L2), and this is what says so out loud when one
    /// starts to.
    func testNoTestBuildsAnAppStateThroughTheShippingInitialiser() throws {
        let registered = TestSourceInventory.registeredNames(inProject: try generatedProject())
        XCTAssertGreaterThan(registered.count, 50,
                             "the project lists almost no Swift files, so this guard is vacuous")

        var offenders: [String] = []
        var scanned = 0
        var seamUses = 0
        for name in registered.sorted() {
            let url = testsDir.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            seamUses += TestSourceInventory.seamUses(in: contents)
            for line in TestSourceInventory.shippingAppStateLines(in: contents) {
                offenders.append("\(name):\(line)")
            }
        }

        // Both controls are here because "no offenders" is what a scanner that
        // read nothing also reports (L98).
        XCTAssertGreaterThan(scanned, 50,
                             "the scanner opened almost no test files, so it has stopped working")
        XCTAssertGreaterThan(seamUses, 10,
                             "the scanner found almost no AppState construction of any kind, so "
                             + "it is reading something other than the test sources")

        XCTAssertTrue(offenders.isEmpty, """
            These tests build an AppState through the shipping initialiser, which reads \
            the real events.json and runs the launch sweeps that delete media for every \
            event not in the list they read:

            \(offenders.joined(separator: "\n"))

            Use the test seam instead, pointed at a temporary tree:

                AppState(events: [], storeURL: <temp>/events.json, dataRoot: <temp>)
            """)
    }

    /// The test seam says where it points, every time (#684).
    ///
    /// Both locations used to carry a default naming the LIVE ones, so a test
    /// that left them out was handed the real events.json and the real media
    /// tree while its call still read as the safe constructor. Seven call sites
    /// were in exactly that state.
    ///
    /// A parameter a function needs in order to be CORRECT must not carry a
    /// default standing for absent (L168): the omission produces live data
    /// instead of a compile error, and it surfaces far away as a rewritten
    /// store or a deleted photo rather than as a refusal.
    ///
    /// Required parameters need no guard at run time, which is the point of
    /// making them required. This guards the REQUIREMENT, because putting a
    /// default back is one word and nothing else here would go red.
    func testTheAppStateTestSeamSaysWhereItPoints() throws {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // PostRollApp
        let source = try String(
            contentsOf: appDir.appendingPathComponent("Sources/AppState.swift"),
            encoding: .utf8)

        let seam = "init(events:"
        guard let opens = source.range(of: seam) else {
            // Gone entirely is fine, for the same reason as the guard above:
            // what is protected is that it cannot point at live data, not that
            // it exists.
            return
        }
        let rest = source[opens.upperBound...]
        let closes = try XCTUnwrap(rest.range(of: ") {"),
                                   "AppState's `\(seam)` seam has no signature this "
                                   + "can read, so nothing below checked anything")
        let signature = String(rest[rest.startIndex..<closes.lowerBound])

        // Without this the assertion below is answered by any parse that came
        // back empty, and empty is what a scanner that stopped working returns
        // (L98).
        for parameter in ["storeURL", "dataRoot"] {
            XCTAssertTrue(signature.contains(parameter),
                          "the seam's signature no longer names \(parameter), so this "
                          + "guard is reading something other than the seam: \(signature)")
        }

        XCTAssertFalse(
            signature.contains("="),
            "AppState's `\(seam)` seam carries a default value: \(signature). Both "
            + "storeURL and dataRoot must be required. A default here is the LIVE "
            + "events.json and the LIVE media tree, handed to any test that leaves it "
            + "out, and the launch sweeps delete media for every event not in the list "
            + "they hold. Take the default off and make each call site say where it points."
        )
    }

    // MARK: - The GUI target launches once (#864)

    /// Launching the app costs about 42 seconds and the testing costs almost
    /// none of it.
    ///
    /// Measured on the runner on 2026-08-23: 43.6 seconds for the first GUI
    /// test and 41.1 seconds for the second, of the SAME binary built by the
    /// same job. The cost is per LAUNCH, not per build, so it is paid again for
    /// every test that starts its own app, and the job grows in 42 second steps
    /// while the amount of real testing does not.
    ///
    /// This holds `AppEntryPointUITests` to one launch. Not because a second
    /// would be wrong, but because it must be a decision somebody takes with the
    /// price in front of them: a test that genuinely needs a cold start should
    /// say so, and the ones that only READ the running app should not pay for
    /// one. Without this the saving quietly disappears the next time a test is
    /// added, and nothing would report it.
    ///
    /// Read from the UI target's source, which is not compiled into this bundle:
    /// a UI test bundle and a unit test bundle cannot be loaded together, so
    /// text is all this can have.
    func testTheGUITargetLaunchesTheAppOnce() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("UITests/AppEntryPointUITests.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
            .joined(separator: "\n")

        let launches = code.components(separatedBy: "LaunchedApp.launch(").count - 1
        XCTAssertEqual(launches, 1, """
            AppEntryPointUITests starts the app \(launches) times. Each one costs \
            about 42 seconds on the runner and the testing in it costs almost \
            nothing, so this is the whole price of the GUI job. Zero means this \
            guard is reading nothing at all and would pass on any file (#864).
            """)
    }
}
