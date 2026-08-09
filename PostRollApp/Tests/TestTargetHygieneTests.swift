import XCTest

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

    func testNoTestableImportOfAppModule() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Build the needle from parts so this guard file doesn't match itself.
        let forbidden = "@testable import " + "PostRoll"
        let selfPath = URL(fileURLWithPath: #filePath).standardizedFileURL.path

        let entries = try FileManager.default.contentsOfDirectory(
            at: testsDir, includingPropertiesForKeys: nil
        )
        var offenders: [String] = []
        for url in entries where url.pathExtension == "swift" {
            if url.standardizedFileURL.path == selfPath { continue }
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents.contains(forbidden) {
                offenders.append(url.lastPathComponent)
            }
        }

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
    func testEveryTestSourceFileIsInTheGeneratedProject() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDir = testsDir.deletingLastPathComponent()   // .../PostRollApp
        let pbxproj = appDir.appendingPathComponent("PostRoll.xcodeproj/project.pbxproj")

        guard let project = try? String(contentsOf: pbxproj, encoding: .utf8) else {
            throw XCTSkip("project.pbxproj not found at \(pbxproj.path); skipping orphan check")
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: testsDir, includingPropertiesForKeys: nil
        )
        var orphans: [String] = []
        for url in entries where url.pathExtension == "swift" {
            if !project.contains(url.lastPathComponent) {
                orphans.append(url.lastPathComponent)
            }
        }

        XCTAssertTrue(
            orphans.isEmpty,
            "These test files exist on disk but aren't in the generated Xcode project, so "
            + "they compile and run only after regeneration (the suite silently skips them): "
            + "\(orphans.joined(separator: ", ")). Run `xcodegen generate` after adding a test file."
        )
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

        let seam = "init(events: [Event])"
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

        let definitions = manifest.components(separatedBy: "POSTROLL_TESTS").count - 1
        XCTAssertEqual(
            definitions, 1,
            "POSTROLL_TESTS must be defined once, on the PostRollTests target only. "
            + "Found \(definitions) mentions in project.yml. Defining it on the app target "
            + "would make every test-only seam reachable from the shipping app."
        )
    }
}
