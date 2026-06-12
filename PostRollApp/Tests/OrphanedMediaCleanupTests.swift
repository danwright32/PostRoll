import XCTest

/// The orphan sweep must delete only media that no event references, and must
/// never touch a file still in use or anything outside the media folders. A bug
/// here deletes the user's imported photos, so the keep/remove boundary and the
/// "shared photo survives" case are pinned.
final class OrphanedMediaCleanupTests: XCTestCase {

    private var photosDir: URL!
    private var audioDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-\(UUID().uuidString)")
        photosDir = base.appendingPathComponent("photos")
        audioDir = base.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: photosDir.deletingLastPathComponent())
    }

    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func event(name: String, photos: [URL], audio: URL? = nil) -> Event {
        var day = PostingDay(day: .wednesday)
        day.photoPaths = photos
        day.audioPath = audio
        var ev = Event(name: name, org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["wednesday"] = day
        return ev
    }

    func testRemovesUnreferencedFileAndKeepsReferenced() throws {
        let kept = try makeFile("kept.jpg", in: photosDir)
        let orphan = try makeFile("orphan.jpg", in: photosDir)
        let ev = event(name: "A", photos: [kept])

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testSharedPhotoSurvivesWhenOneEventDeleted() throws {
        // The same file referenced by two events must not be deleted while
        // either still references it.
        let shared = try makeFile("shared.jpg", in: photosDir)
        let evA = event(name: "A", photos: [shared])
        let evB = event(name: "B", photos: [shared])

        // Delete A: B still references the file -> survives.
        let removed = OrphanedMediaCleanup.sweep(events: [evB], photosDir: photosDir, audioDir: audioDir)
        _ = evA
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
    }

    func testCleansAudioDirToo() throws {
        let keptAudio = try makeFile("song.m4a", in: audioDir)
        let orphanAudio = try makeFile("old.m4a", in: audioDir)
        let ev = event(name: "A", photos: [], audio: keptAudio)

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanAudio.path))
    }

    func testNoEventsRemovesAllOrphans() throws {
        // With zero events every file is an orphan. (AppState guards against
        // running this on a failed load; here we assert the mechanics.)
        _ = try makeFile("a.jpg", in: photosDir)
        _ = try makeFile("b.jpg", in: photosDir)
        let removed = OrphanedMediaCleanup.sweep(events: [], photosDir: photosDir, audioDir: audioDir)
        XCTAssertEqual(removed, 2)
    }

    func testReferencedPathsCollectsAllMediaFields() throws {
        let p = try makeFile("p.jpg", in: photosDir)
        let raw = try makeFile("raw.jpg", in: photosDir)
        let bw = try makeFile("bw.jpg", in: photosDir)
        var day = PostingDay(day: .tuesday)
        day.photoPaths = [p]
        day.rawPhotoPath = raw
        day.bwPhotoPath = bw
        day.collageCellOverride = [CollageCell(photoPath: p.path, x: 0, y: 0, w: 1, h: 1)]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["tuesday"] = day

        let refs = OrphanedMediaCleanup.referencedPaths(in: [ev])
        XCTAssertTrue(refs.contains(p.standardizedFileURL.path))
        XCTAssertTrue(refs.contains(raw.standardizedFileURL.path))
        XCTAssertTrue(refs.contains(bw.standardizedFileURL.path))
    }
}
