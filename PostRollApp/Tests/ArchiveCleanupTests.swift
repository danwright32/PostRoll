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

        let dirty = ArchiveCleanup.sweep(events: &events, projectRoot: root)

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

        _ = ArchiveCleanup.sweep(events: &events, projectRoot: root)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.path),
            "preview folder shared with a live duplicate must survive"
        )
        XCTAssertFalse(events[1].previewMediaPaths.isEmpty,
                       "the duplicate's preview paths must be untouched")
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
        _ = ArchiveCleanup.sweep(events: &events, projectRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path),
                      "scan referenced by the live duplicate must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unshared.path),
                       "scan only the archived event references is reclaimed")
    }
}
