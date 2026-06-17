import XCTest

/// Covers reclaiming the duplicated legacy ~/Documents/PostRoll data after the
/// Application Support migration (#47). The dangerous part is deleting from a
/// folder that also holds the Python checkout, so these pin that only the data
/// allowlist is touched and only when the move is verified complete.
final class LegacyDataReclaimTests: XCTestCase {

    private var tmp: URL!
    private var legacy: URL!
    private var appSupport: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("reclaim-\(UUID().uuidString)")
        legacy = tmp.appendingPathComponent("Documents/PostRoll")
        appSupport = tmp.appendingPathComponent("AppSupport/PostRoll")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func file(_ root: URL, _ rel: String, _ bytes: String = "x") throws {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
    }

    private func emptyDir(_ root: URL, _ rel: String) throws {
        try fm.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
    }

    private func markMigrated() throws {
        try Data().write(to: appSupport.appendingPathComponent(AppPaths.migrationMarker))
    }

    private func exists(_ root: URL, _ rel: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(rel).path)
    }

    private func reclaim() throws -> LegacyDataReclaim.Report {
        try LegacyDataReclaim.reclaim(
            legacyRoot: legacy, appSupportRoot: appSupport, activeRoot: appSupport, fileManager: fm)
    }

    // MARK: - canReclaim gating

    func testCannotReclaimWithoutMarker() {
        XCTAssertFalse(LegacyDataReclaim.canReclaim(
            appSupportRoot: appSupport, activeRoot: appSupport, fileManager: fm))
    }

    func testCannotReclaimWhenStillReadingLegacyRoot() throws {
        try markMigrated()
        // Active root is still the legacy location → the originals are live data.
        XCTAssertFalse(LegacyDataReclaim.canReclaim(
            appSupportRoot: appSupport, activeRoot: legacy, fileManager: fm))
    }

    func testCanReclaimWhenMigratedAndActiveOnAppSupport() throws {
        try markMigrated()
        XCTAssertTrue(LegacyDataReclaim.canReclaim(
            appSupportRoot: appSupport, activeRoot: appSupport, fileManager: fm))
    }

    // MARK: - Reclaim behaviour

    func testDeletesMigratedDataButLeavesTheCheckout() throws {
        try markMigrated()
        // Legacy holds data AND the Python checkout.
        try file(legacy, "photos/IMG_1.jpg")
        try file(legacy, "programs/p1.png")
        try file(legacy, "events.json", "{}")
        try file(legacy, "postroll/ai/claude_client.py", "code")
        try file(legacy, "venv/bin/python", "bin")
        try file(legacy, ".git/HEAD", "ref")
        try file(legacy, "Makefile", "all:")
        // App Support has the migrated, non-empty counterparts.
        try file(appSupport, "photos/IMG_1.jpg")
        try file(appSupport, "programs/p1.png")
        try file(appSupport, "events.json", "{}")

        let report = try reclaim()

        // Allowlisted data gone from legacy…
        XCTAssertFalse(exists(legacy, "photos"))
        XCTAssertFalse(exists(legacy, "programs"))
        XCTAssertFalse(exists(legacy, "events.json"))
        XCTAssertEqual(Set(report.removed), ["photos", "programs", "events.json"])
        // …checkout untouched.
        XCTAssertTrue(exists(legacy, "postroll/ai/claude_client.py"))
        XCTAssertTrue(exists(legacy, "venv/bin/python"))
        XCTAssertTrue(exists(legacy, ".git/HEAD"))
        XCTAssertTrue(exists(legacy, "Makefile"))
    }

    func testSkipsItemWhoseCounterpartIsMissingOrEmpty() throws {
        try markMigrated()
        try file(legacy, "audio/track.m4a")          // legacy has it
        try emptyDir(appSupport, "audio")            // but App Support copy is empty
        try file(legacy, "photos/IMG.jpg")           // legacy has it
        // no App Support photos at all

        let report = try reclaim()

        XCTAssertTrue(report.removed.isEmpty, "nothing with an unverified copy may be deleted")
        XCTAssertTrue(exists(legacy, "audio/track.m4a"))
        XCTAssertTrue(exists(legacy, "photos/IMG.jpg"))
    }

    func testNoopWhenNotMigrated() throws {
        // No marker: even allowlisted items must survive (they're the live data).
        try file(legacy, "photos/IMG.jpg")
        try file(appSupport, "photos/IMG.jpg")

        let report = try reclaim()

        XCTAssertEqual(report, LegacyDataReclaim.Report(removed: [], bytesFreed: 0))
        XCTAssertTrue(exists(legacy, "photos/IMG.jpg"))
    }

    func testReclaimableBytesCountsOnlyVerifiedItems() throws {
        try markMigrated()
        try file(legacy, "photos/a.jpg", "1234567890")   // 10 bytes
        try file(appSupport, "photos/a.jpg", "1234567890")
        try file(legacy, "audio/x.m4a", "zzzz")          // 4 bytes, but no counterpart
        let bytes = LegacyDataReclaim.reclaimableBytes(
            legacyRoot: legacy, appSupportRoot: appSupport, activeRoot: appSupport, fileManager: fm)
        XCTAssertEqual(bytes, 10)
    }
}
