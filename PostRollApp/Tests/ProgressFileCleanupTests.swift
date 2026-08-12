import XCTest

/// #235: an event's progress file goes when the event does.
///
/// Every generation run writes its current step to a per-event file that is
/// deliberately left behind afterwards, so a finished run's last step stays
/// readable. Nothing ever deleted one, so deleting an event left its file on
/// disk forever. Tiny files, so this is housekeeping, and the reason it is
/// worth doing is that the app now has one answer to who clears up per-event
/// scratch files rather than none.
///
/// The keep/remove boundary is pinned the same way `OrphanedMediaCleanupTests`
/// pins the media sweep's, because the failure mode is the same in kind:
/// deleting something that is still in use.
final class ProgressFileCleanupTests: XCTestCase {

    private var progressDir: URL!

    override func setUpWithError() throws {
        progressDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: progressDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: progressDir)
    }

    private func writeProgress(for id: UUID) throws -> URL {
        let url = progressDir.appendingPathComponent("\(id.uuidString).json")
        try Data(#"{"step":"Wednesday collage"}"#.utf8).write(to: url)
        return url
    }

    private func event(named name: String = "Test") -> Event {
        Event(name: name, org: "Org", venue: "Venue", date: Date(), shootType: .fullShow)
    }

    func testItRemovesTheFileOfAnEventThatIsGone() throws {
        let orphan = try writeProgress(for: UUID())

        let removed = ProgressFileCleanup.sweep(events: [], progressDir: progressDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(removed, [orphan.lastPathComponent],
                       "the sweep names what it took, so a wrong delete leaves a record")
    }

    func testItKeepsTheFileOfAnEventThatStillExists() throws {
        let live = event()
        let kept = try writeProgress(for: live.id)

        let removed = ProgressFileCleanup.sweep(events: [live], progressDir: progressDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(removed.isEmpty)
    }

    func testItKeepsALiveEventsFileWhileRemovingADeadOnesInTheSamePass() throws {
        let live = event()
        let kept = try writeProgress(for: live.id)
        let orphan = try writeProgress(for: UUID())

        ProgressFileCleanup.sweep(events: [live], progressDir: progressDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    // ── what it refuses to touch ──────────────────────────────────────────────

    func testItLeavesAFileWhoseNameIsNotAnEventID() throws {
        let stranger = progressDir.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: stranger)

        ProgressFileCleanup.sweep(events: [], progressDir: progressDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path),
                      "the sweep only owns the <uuid>.json files this app writes")
    }

    func testItLeavesAFileThatIsNotJSON() throws {
        let stranger = progressDir.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: stranger)

        ProgressFileCleanup.sweep(events: [], progressDir: progressDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    func testItLeavesDirectoriesAlone() throws {
        let nested = progressDir.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        ProgressFileCleanup.sweep(events: [], progressDir: progressDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testAMissingProgressDirectoryIsNotAnError() {
        let never = progressDir.appendingPathComponent("never-created")
        XCTAssertEqual(ProgressFileCleanup.sweep(events: [], progressDir: never), [])
    }
}
