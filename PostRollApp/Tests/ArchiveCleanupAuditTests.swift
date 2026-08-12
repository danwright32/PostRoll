import XCTest

/// #108: every reclaim leaves a record.
///
/// The sweep deletes a preview folder identified by a name it re-derives, and
/// deletes it months after the export, so a mistargeted delete was completely
/// silent: the folder is simply gone with nothing anywhere saying what took it.
final class ArchiveCleanupAuditTests: XCTestCase {

    private var dataRoot: URL!

    override func setUpWithError() throws {
        dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataRoot)
    }

    /// An event archived long enough ago to be swept, with a preview folder.
    private func makeArchivedEvent() throws -> Event {
        var event = Event(name: "Vocal Colors", org: "DCINY", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        event.stage = .exported
        event.archivedAt = Date(timeIntervalSinceNow: -Double(ArchiveCleanup.archiveAgeDays + 1) * 86_400)
        let previewDir = dataRoot.appendingPathComponent("preview")
            .appendingPathComponent(ArchiveCleanup.slug(event: event))
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: previewDir.appendingPathComponent("collage.png"))
        return event
    }

    func testItRecordsThePathItRemoved() throws {
        var events = [try makeArchivedEvent()]
        let expectedFolder = dataRoot.appendingPathComponent("preview")
            .appendingPathComponent(ArchiveCleanup.slug(event: events[0])).path

        var seen: [ArchiveCleanup.Reclaim] = []
        ArchiveCleanup.sweep(events: &events, dataRoot: dataRoot) { seen.append($0) }

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.removed, [expectedFolder],
                       "a delete nothing recorded is a delete nobody can trace")
        XCTAssertEqual(seen.first?.eventName, "Vocal Colors")
    }

    func testItRecordsTheSlugItUsedToFindTheFolder() throws {
        // The slug is the whole identification step. When a wrong folder goes,
        // the slug is the first thing anyone would want to see.
        var events = [try makeArchivedEvent()]
        var seen: [ArchiveCleanup.Reclaim] = []
        ArchiveCleanup.sweep(events: &events, dataRoot: dataRoot) { seen.append($0) }

        XCTAssertEqual(seen.first?.slug, "dciny_vocal_colors_\(events[0].isoDate)")
    }

    func testTheDefaultSinkWritesUnderTheDataRootItWasGiven() throws {
        // Not under AppPaths.root: a default reaching the real data root would
        // make a test of a temporary directory append to the live audit log.
        var events = [try makeArchivedEvent()]
        ArchiveCleanup.sweep(events: &events, dataRoot: dataRoot)

        let log = ArchiveCleanup.auditLog(dataRoot: dataRoot)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("Vocal Colors"), text)
        XCTAssertTrue(text.contains("preview/dciny_vocal_colors"), text)
    }

    func testASweepThatRemovedNothingWritesNothing() throws {
        var event = try makeArchivedEvent()
        event.archivedAt = Date()          // too recent to sweep
        var events = [event]

        var seen: [ArchiveCleanup.Reclaim] = []
        ArchiveCleanup.sweep(events: &events, dataRoot: dataRoot) { seen.append($0) }

        XCTAssertTrue(seen.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ArchiveCleanup.auditLog(dataRoot: dataRoot).path),
            "a log line per uneventful launch is how a real one stops being read")
    }

    func testASecondReclaimAppendsRatherThanReplacing() throws {
        var first = [try makeArchivedEvent()]
        ArchiveCleanup.sweep(events: &first, dataRoot: dataRoot)

        var second = try makeArchivedEvent()
        second.name = "Perpetual Light"
        let dir = dataRoot.appendingPathComponent("preview")
            .appendingPathComponent(ArchiveCleanup.slug(event: second))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var events = [second]
        ArchiveCleanup.sweep(events: &events, dataRoot: dataRoot)

        let text = try String(contentsOf: ArchiveCleanup.auditLog(dataRoot: dataRoot), encoding: .utf8)
        XCTAssertTrue(text.contains("Vocal Colors"), text)
        XCTAssertTrue(text.contains("Perpetual Light"), text)
    }
}
