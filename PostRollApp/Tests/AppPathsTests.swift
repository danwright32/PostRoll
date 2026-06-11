import XCTest

/// Pins the data directory override contract (issue #34): every store
/// resolves its path through AppPaths, and POSTROLL_DATA_DIR redirects the
/// whole tree so tests and UI automation can never touch live data.
final class AppPathsTests: XCTestCase {

    func testDefaultRootIsDocumentsPostRoll() {
        let root = AppPaths.resolveRoot(environment: [:])
        XCTAssertEqual(
            root,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PostRoll")
        )
    }

    func testOverrideRedirectsRoot() {
        let root = AppPaths.resolveRoot(environment: ["POSTROLL_DATA_DIR": "/tmp/postroll-sandbox"])
        XCTAssertEqual(root.path, "/tmp/postroll-sandbox")
    }

    func testBlankOverrideFallsBackToDefault() {
        let root = AppPaths.resolveRoot(environment: ["POSTROLL_DATA_DIR": "   "])
        XCTAssertEqual(
            root,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PostRoll")
        )
    }

    func testDerivedPathsHangOffRoot() {
        XCTAssertEqual(AppPaths.eventsFile, AppPaths.root.appendingPathComponent("events.json"))
        XCTAssertEqual(AppPaths.analyticsFile, AppPaths.root.appendingPathComponent("analytics.json"))
        XCTAssertEqual(AppPaths.programsDir, AppPaths.root.appendingPathComponent("programs"))
        XCTAssertEqual(AppPaths.photosDir, AppPaths.root.appendingPathComponent("photos"))
        XCTAssertEqual(AppPaths.audioDir, AppPaths.root.appendingPathComponent("audio"))
    }
}
