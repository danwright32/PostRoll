import XCTest

/// Deleting an event offers an Undo for a few seconds, so the event's media
/// must still be on disk when the user takes it (issue #78). The rule is that
/// an event awaiting undo still counts as an owner of its files, while every
/// other orphan is still reclaimed on time.
final class DeletionPolicyTests: XCTestCase {

    private var photosDir: URL!
    private var audioDir: URL!
    private var programsDir: URL!
    private var clipsDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("deletion-policy-\(UUID().uuidString)")
        photosDir = base.appendingPathComponent("photos")
        audioDir = base.appendingPathComponent("audio")
        programsDir = base.appendingPathComponent("programs")
        clipsDir = base.appendingPathComponent("clips")
        for dir in [photosDir!, audioDir!, programsDir!, clipsDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: photosDir.deletingLastPathComponent())
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = photosDir.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func event(name: String, photos: [URL]) -> Event {
        var day = PostingDay(day: .wednesday)
        day.photoPaths = photos
        var ev = Event(name: name, org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["wednesday"] = day
        return ev
    }

    private func sweep(_ events: [Event]) -> Int {
        OrphanedMediaCleanup.sweep(
            events: events,
            photosDir: photosDir,
            audioDir: audioDir,
            programsDir: programsDir,
            clipsDir: clipsDir
        )
    }

    func testPendingDeletionStillOwnsItsMedia() {
        let kept = event(name: "Kept", photos: [])
        let deleted = event(name: "Deleted", photos: [])

        let owners = DeletionPolicy.mediaOwners(events: [kept], pendingDeletion: deleted)

        XCTAssertEqual(owners.map(\.id), [kept.id, deleted.id])
    }

    func testWithNothingPendingTheListIsUnchanged() {
        let kept = event(name: "Kept", photos: [])

        let owners = DeletionPolicy.mediaOwners(events: [kept], pendingDeletion: nil)

        XCTAssertEqual(owners.map(\.id), [kept.id])
    }

    func testSweepDuringTheUndoWindowKeepsTheDeletedEventsPhotos() throws {
        let survivor = try makeFile("survivor.jpg")
        let undoable = try makeFile("undoable.jpg")
        let orphan = try makeFile("orphan.jpg")
        let kept = event(name: "Kept", photos: [survivor])
        let deleted = event(name: "Deleted", photos: [undoable])

        // The state right after a delete: `deleted` is out of the list but the
        // Undo banner is still up.
        let removed = sweep(DeletionPolicy.mediaOwners(events: [kept], pendingDeletion: deleted))

        XCTAssertEqual(removed, 1, "only the real orphan should go")
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: undoable.path),
            "undo would restore an event whose photos had already been deleted"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "unrelated orphans still get reclaimed")
    }

    func testOnceTheUndoWindowClosesTheMediaIsReclaimed() throws {
        let survivor = try makeFile("survivor.jpg")
        let undoable = try makeFile("undoable.jpg")
        let kept = event(name: "Kept", photos: [survivor])
        let deleted = event(name: "Deleted", photos: [undoable])

        _ = sweep(DeletionPolicy.mediaOwners(events: [kept], pendingDeletion: deleted))
        // The window closed without an undo, so the event is gone for good.
        let removed = sweep(DeletionPolicy.mediaOwners(events: [kept], pendingDeletion: nil))

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: undoable.path))
    }
}
