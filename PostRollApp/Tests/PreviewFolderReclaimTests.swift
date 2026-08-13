import XCTest

/// #482: deleting an event reclaimed N-1 of its N derived resources.
///
/// The orphan sweep covered photos, audio, programs and clips, and the only
/// code that ever deleted a preview folder was `ArchiveCleanup`, which iterates
/// events still in the store. So a deleted event's rendered reels, collages,
/// story graphics and layout sidecars were reclaimed by nothing at all and
/// leaked forever, on the machine whose disk has been filled by exactly this
/// class before (L38).
final class PreviewFolderReclaimTests: XCTestCase {
    private var root: URL!
    private var previewDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewReclaim-\(UUID().uuidString)")
        previewDir = root.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func anEvent(name: String, org: String = "Decoda") -> Event {
        Event(name: name, org: org, venue: "Hall",
              date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
    }

    /// A rendered preview folder for `event`, with a reel in it.
    @discardableResult
    private func writePreview(for event: Event) throws -> URL {
        let dir = previewDir.appendingPathComponent(ArchiveCleanup.slug(event: event))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("a rendered reel".utf8).write(to: dir.appendingPathComponent("reel.mp4"))
        return dir
    }

    private func folders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: previewDir.path)) ?? []).sorted()
    }

    func testAFolderWhoseEventIsGoneIsReclaimed() throws {
        let deleted = anEvent(name: "Music From Inside")
        try writePreview(for: deleted)

        let removed = OrphanedMediaCleanup.sweepPreviewFolders(events: [], previewDir: previewDir)

        XCTAssertEqual(removed.count, 1, "the deleted event's preview folder was left behind")
        XCTAssertTrue(folders().isEmpty, folders().description)
    }

    func testALiveEventKeepsItsPreviews() throws {
        let live = anEvent(name: "Music From Inside")
        try writePreview(for: live)

        OrphanedMediaCleanup.sweepPreviewFolders(events: [live], previewDir: previewDir)

        XCTAssertEqual(folders(), [ArchiveCleanup.slug(event: live)],
                       "a live event's rendered previews were deleted")
    }

    func testADuplicateSharingASlugKeepsTheFolderAlive() throws {
        // duplicateEvent copies org, name and date verbatim, so a live duplicate
        // shares this event's folder. Deleting one must not take the other's
        // previews with it.
        let original = anEvent(name: "Music From Inside")
        let duplicate = anEvent(name: "Music From Inside")
        XCTAssertEqual(ArchiveCleanup.slug(event: original), ArchiveCleanup.slug(event: duplicate))
        try writePreview(for: original)

        OrphanedMediaCleanup.sweepPreviewFolders(events: [duplicate], previewDir: previewDir)

        XCTAssertEqual(folders().count, 1,
                       "a folder a live duplicate still renders into was reclaimed")
    }

    func testOnlyTheGoneEventsFolderGoes() throws {
        let live = anEvent(name: "Still Here")
        let gone = anEvent(name: "Deleted Show")
        try writePreview(for: live)
        try writePreview(for: gone)

        let removed = OrphanedMediaCleanup.sweepPreviewFolders(events: [live], previewDir: previewDir)

        XCTAssertEqual(removed, [ArchiveCleanup.slug(event: gone)])
        XCTAssertEqual(folders(), [ArchiveCleanup.slug(event: live)])
    }

    func testLooseFilesBesideTheFoldersAreLeftAlone() throws {
        // Only per-event folders are this sweep's business. Deleting a file it
        // does not understand is how a cleanup becomes the incident.
        try Data("something else".utf8).write(to: previewDir.appendingPathComponent("notes.txt"))

        OrphanedMediaCleanup.sweepPreviewFolders(events: [], previewDir: previewDir)

        XCTAssertEqual(folders(), ["notes.txt"])
    }

    func testAMissingPreviewFolderIsNotAFailure() {
        // Nothing rendered yet is the ordinary first-launch state.
        let absent = root.appendingPathComponent("no-preview-here")
        XCTAssertEqual(OrphanedMediaCleanup.sweepPreviewFolders(events: [], previewDir: absent), [])
    }

    func testAnUnreadableFolderDeletesNothing() throws {
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
        let event = anEvent(name: "Deleted Show")
        try writePreview(for: event)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: previewDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: previewDir.path)
        }

        // Deleting nothing is the right answer for a folder we could not read.
        // The leak carries on, which is why the code says so in the log rather
        // than treating it as a clean sweep (L11).
        XCTAssertEqual(OrphanedMediaCleanup.sweepPreviewFolders(events: [], previewDir: previewDir),
                       [])
    }

    // MARK: - Wired, not just built (L3)

    /// The sweep existing is worth nothing while nothing calls it, which is
    /// what the whole issue was: the function that reclaims a preview folder
    /// was there, and no delete path ever reached it.
    @MainActor
    func testDeletingAnEventReclaimsItsPreviewFolderForReal() throws {
        let store = root.appendingPathComponent("events.json")
        let event = anEvent(name: "Deleted Show")
        try writePreview(for: event)

        let app = AppState(events: [event], storeURL: store, dataRoot: root)
        app.deleteEvent(id: event.id)

        // Still there inside the undo window: an undo has to put back a working
        // event, not one whose graphics were reclaimed a second earlier.
        XCTAssertEqual(folders(), [ArchiveCleanup.slug(event: event)],
                       "the previews went before the undo window closed")

        app.finalizePendingDeletion()

        XCTAssertTrue(folders().isEmpty,
                      "the delete left \(folders()) behind for good")
    }

    @MainActor
    func testAnUndoneDeleteKeepsThePreviews() throws {
        let store = root.appendingPathComponent("events.json")
        let event = anEvent(name: "Nearly Deleted")
        try writePreview(for: event)

        let app = AppState(events: [event], storeURL: store, dataRoot: root)
        app.deleteEvent(id: event.id)
        app.undoDelete()

        XCTAssertEqual(folders(), [ArchiveCleanup.slug(event: event)],
                       "undo restored an event whose graphics had been reclaimed")
    }
}
