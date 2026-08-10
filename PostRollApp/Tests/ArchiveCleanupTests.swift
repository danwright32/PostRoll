import XCTest

/// Pins the archive cleanup sharing contract (issue #32): a duplicated
/// event copies org, name, date, and program image paths verbatim, so it
/// shares the original's preview folder slug and program scans. Sweeping
/// the archived original must never delete anything the live duplicate
/// still references.
final class ArchiveCleanupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("preview"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("programs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("output"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeArchivedEvent(name: String = "Spring Show") -> Event {
        var event = Event(
            name: name, org: "Org", venue: "Hall",
            date: Date(timeIntervalSinceNow: -200 * 86_400),
            shootType: .fullShow
        )
        event.stage = .exported
        event.archivedAt = Date(timeIntervalSinceNow: -100 * 86_400)
        return event
    }

    private func previewDir(for event: Event) throws -> URL {
        // Mirror the slug convention: slug(org)_slug(name)_isoDate
        let slug = "org_spring_show_\(event.isoDate)"
        let dir = root.appendingPathComponent("preview").appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: dir.appendingPathComponent("story.png"))
        return dir
    }

    func testArchivedEventPreviewIsReclaimed() throws {
        var events = [makeArchivedEvent()]
        events[0].previewMediaPaths = ["sunday": ["story": "/x"]]
        let dir = try previewDir(for: events[0])

        let dirty = ArchiveCleanup.sweep(events: &events, dataRoot: root)

        XCTAssertTrue(dirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(events[0].previewMediaPaths.isEmpty)
    }

    func testSharedSlugPreviewSurvivesSweep() throws {
        var original = makeArchivedEvent()
        original.previewMediaPaths = ["sunday": ["story": "/x"]]
        // The duplicate: same org/name/date (same slug), different id, live
        var duplicate = original
        duplicate.id = UUID()
        duplicate.stage = .photosAssigned
        duplicate.archivedAt = nil
        duplicate.previewMediaPaths = ["sunday": ["story": "/x"]]

        var events = [original, duplicate]
        let dir = try previewDir(for: original)

        _ = ArchiveCleanup.sweep(events: &events, dataRoot: root)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.path),
            "preview folder shared with a live duplicate must survive"
        )
        XCTAssertFalse(events[1].previewMediaPaths.isEmpty,
                       "the duplicate's preview paths must be untouched")
    }

    func testUnstampedExportedEventIsStampedNotSwept() throws {
        // An event exported before archivedAt existed must get the full
        // grace period from now, not be swept based on its old shoot date.
        var events = [makeArchivedEvent()]
        events[0].archivedAt = nil
        events[0].previewMediaPaths = ["sunday": ["story": "/x"]]
        let dir = try previewDir(for: events[0])

        let dirty = ArchiveCleanup.sweep(events: &events, dataRoot: root)

        XCTAssertTrue(dirty, "the stamp must be persisted")
        XCTAssertNotNil(events[0].archivedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "nothing is reclaimed on the stamping pass")
        XCTAssertFalse(events[0].previewMediaPaths.isEmpty)
    }

    func testSharedProgramScansSurviveSweep() throws {
        let programs = root.appendingPathComponent("programs")
        let shared = programs.appendingPathComponent("program_p1.png")
        let unshared = programs.appendingPathComponent("program_p2.png")
        try Data("a".utf8).write(to: shared)
        try Data("b".utf8).write(to: unshared)

        var original = makeArchivedEvent()
        original.programImagePaths = [shared, unshared]
        var duplicate = original
        duplicate.id = UUID()
        duplicate.stage = .programUploaded
        duplicate.archivedAt = nil
        duplicate.name = "Different Name"  // different slug, shared scans
        duplicate.programImagePaths = [shared]

        var events = [original, duplicate]
        _ = ArchiveCleanup.sweep(events: &events, dataRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path),
                      "scan referenced by the live duplicate must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unshared.path),
                       "scan only the archived event references is reclaimed")
    }
}

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
