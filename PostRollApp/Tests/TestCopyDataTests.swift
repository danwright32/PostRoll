import XCTest

/// #1425: a copy of PostRoll that is not the installed one keeps its own data.
///
/// On 2026-09-26 four builds opened from worktrees to look at a change each
/// read and re-saved Dan's real events.json, because every copy of the app
/// resolved the same data folder. No harm that day, but a build whose model
/// differs re-encodes the store on save and changes his real events for good
/// (L267, L719). So the installed copy alone uses the real folder; any other
/// copy uses its own, refreshed from the real events at launch so there is
/// something to look at, and whatever it saves is thrown away next launch.
final class TestCopyDataTests: XCTestCase {

    private final class MarkerFM: FileManager {
        override func fileExists(atPath path: String) -> Bool {
            if path.hasSuffix("/" + AppPaths.migrationMarker) { return true }
            return super.fileExists(atPath: path)
        }
    }

    private let elsewhere = URL(fileURLWithPath:
        "/Users/someone/Library/Developer/PostRoll/Build/Products/Release/PostRoll.app")

    func testTheInstalledCopyUsesTheRealData() {
        let root = AppPaths.resolveRoot(environment: [:], fileManager: MarkerFM(),
                                        bundleURL: AppPaths.installedBundle,
                                        refresh: { _, _ in XCTFail("the installed copy was refreshed") })
        XCTAssertEqual(root, AppPaths.appSupportRoot)
    }

    func testAnyOtherCopyUsesItsOwnFolder() {
        var refreshed: [(URL, URL)] = []
        let root = AppPaths.resolveRoot(environment: [:], fileManager: MarkerFM(),
                                        bundleURL: elsewhere,
                                        refresh: { refreshed.append(($0, $1)) })
        XCTAssertEqual(root, AppPaths.checkingRoot)
        XCTAssertNotEqual(root, AppPaths.appSupportRoot)
        XCTAssertEqual(refreshed.count, 1, "a test copy opened with nothing to look at")
        XCTAssertEqual(refreshed.first?.0, AppPaths.appSupportRoot, "refreshed from the wrong place")
        XCTAssertEqual(refreshed.first?.1, AppPaths.checkingRoot)
    }

    func testTheTestSuiteNeverCopiesTheRealEvents() {
        // A unit test process is itself a copy that is not the installed one.
        // It gets the separate folder and never a copy of Dan's events.
        let root = AppPaths.resolveRoot(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            fileManager: MarkerFM(), bundleURL: elsewhere,
            refresh: { _, _ in XCTFail("a test run copied the real events") })
        XCTAssertEqual(root, AppPaths.checkingRoot)
    }

    func testAnExplicitDataFolderStillWins() {
        let root = AppPaths.resolveRoot(environment: ["POSTROLL_DATA_DIR": "/tmp/postroll-sandbox"],
                                        fileManager: MarkerFM(), bundleURL: elsewhere,
                                        refresh: { _, _ in XCTFail("an explicit folder was refreshed") })
        XCTAssertEqual(root.path, "/tmp/postroll-sandbox")
    }

    // MARK: - The refresh

    private func scratch() throws -> (real: URL, checking: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-copy-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let checking = base.appendingPathComponent("checking")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (real, checking)
    }

    func testTheRefreshReplacesWhateverTheLastTestCopySaved() throws {
        let (real, checking) = try scratch()
        try Data("real events".utf8).write(to: real.appendingPathComponent("events.json"))
        try FileManager.default.createDirectory(at: checking, withIntermediateDirectories: true)
        try Data("edited by a test copy".utf8).write(to: checking.appendingPathComponent("events.json"))

        AppPaths.refreshCheckingCopy(from: real, to: checking)

        XCTAssertEqual(try String(contentsOf: checking.appendingPathComponent("events.json"), encoding: .utf8),
                       "real events")
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("events.json"), encoding: .utf8),
                       "real events", "the refresh touched the real store")
    }

    func testNoRealEventsLeavesTheCopyEmptyRatherThanStale() throws {
        let (real, checking) = try scratch()
        try FileManager.default.createDirectory(at: checking, withIntermediateDirectories: true)
        try Data("left from last time".utf8).write(to: checking.appendingPathComponent("events.json"))

        AppPaths.refreshCheckingCopy(from: real, to: checking)

        XCTAssertFalse(FileManager.default.fileExists(atPath: checking.appendingPathComponent("events.json").path),
                       "a stale copy stood in for events that no longer exist")
    }
}
