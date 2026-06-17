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
}
