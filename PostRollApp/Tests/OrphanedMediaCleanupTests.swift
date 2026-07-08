import XCTest

/// The orphan sweep must delete only media that no event references, and must
/// never touch a file still in use or anything outside the media folders. A bug
/// here deletes the user's imported photos, so the keep/remove boundary and the
/// "shared photo survives" case are pinned.
final class OrphanedMediaCleanupTests: XCTestCase {

    private var photosDir: URL!
    private var audioDir: URL!
    private var programsDir: URL!
    private var clipsDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-\(UUID().uuidString)")
        photosDir = base.appendingPathComponent("photos")
        audioDir = base.appendingPathComponent("audio")
        programsDir = base.appendingPathComponent("programs")
        clipsDir = base.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: programsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
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

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testRefusesToMassDeleteWhenMostFilesLookUnreferenced() throws {
        // Regression: a double-encoded events.json made every photo look
        // unreferenced, so the sweep deleted the whole library. When more than
        // half a folder looks orphaned, that's a reference-set bug, not real
        // orphans — the sweep must refuse and delete nothing.
        var files: [URL] = []
        for i in 0..<10 { files.append(try makeFile("p\(i).jpg", in: photosDir)) }
        // Only 2 of 10 referenced → 8 "orphans" → must trip the safety backstop.
        let ev = event(name: "A", photos: [files[0], files[1]])

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)

        XCTAssertEqual(removed, 0, "a suspicious mass deletion must be refused")
        for f in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "nothing should be deleted")
        }
    }

    func testStillDeletesAFewGenuineOrphans() throws {
        // The backstop must not block a normal sweep: most files referenced,
        // a couple genuinely orphaned → those couple are removed.
        var files: [URL] = []
        for i in 0..<10 { files.append(try makeFile("p\(i).jpg", in: photosDir)) }
        let referenced = Array(files[0..<8])  // 8 referenced, 2 orphans
        let ev = event(name: "A", photos: referenced)

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[8].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[9].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path))
    }

    func testSharedPhotoSurvivesWhenOneEventDeleted() throws {
        // The same file referenced by two events must not be deleted while
        // either still references it.
        let shared = try makeFile("shared.jpg", in: photosDir)
        let evA = event(name: "A", photos: [shared])
        let evB = event(name: "B", photos: [shared])

        // Delete A: B still references the file -> survives.
        let removed = OrphanedMediaCleanup.sweep(events: [evB], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)
        _ = evA
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
    }

    func testCleansAudioDirToo() throws {
        let keptAudio = try makeFile("song.m4a", in: audioDir)
        let orphanAudio = try makeFile("old.m4a", in: audioDir)
        let ev = event(name: "A", photos: [], audio: keptAudio)

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanAudio.path))
    }

    // Friday auto-cut clip reel (#131): freshly imported clips must survive
    // the sweep, or the very next background run permanently deletes footage
    // that usually can't be reshot.
    func testCleansClipsDirToo() throws {
        let keptClip = try makeFile("show.mov", in: clipsDir)
        let orphanClip = try makeFile("old.mov", in: clipsDir)
        var day = PostingDay(day: .friday)
        day.clipPaths = [keptClip]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["friday"] = day

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptClip.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanClip.path))
    }

    func testReferencedPathsCollectsClipPathsAndOverrideEntries() throws {
        let clip = try makeFile("show.mov", in: clipsDir)
        let overrideOnlyClip = try makeFile("override-only.mov", in: clipsDir)
        var day = PostingDay(day: .friday)
        day.clipPaths = [clip]
        day.fridayClipOverride = [
            ReelClipOverride(clipPath: overrideOnlyClip.path, order: 0, included: true, trimIn: 0, trimOut: 5)
        ]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["friday"] = day

        let refs = OrphanedMediaCleanup.referencedPaths(in: [ev])
        XCTAssertTrue(refs.contains(clip.standardizedFileURL.path))
        XCTAssertTrue(refs.contains(overrideOnlyClip.standardizedFileURL.path), "an override entry protects its clip even if clipPaths itself doesn't list it")
    }

    func testNoEventsRemovesAllOrphans() throws {
        // With zero events every file is an orphan. (AppState guards against
        // running this on a failed load; here we assert the mechanics.)
        _ = try makeFile("a.jpg", in: photosDir)
        _ = try makeFile("b.jpg", in: photosDir)
        let removed = OrphanedMediaCleanup.sweep(events: [], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)
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

    // programs/ sweep (#54): deletes program files from deleted events, but
    // protects every live event's pages, baked PDF, and retained source PDF.

    func testCleansProgramsDirAndKeepsReferencedPages() throws {
        let page = try makeFile("Prog_p1.png", in: programsDir)
        let orphan = try makeFile("OldProg_p1.png", in: programsDir)
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.programImagePaths = [page]

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: page.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testKeepsBakedPdfAndRetainedSourceForLiveEvent() throws {
        let page = try makeFile("Recital_p1.png", in: programsDir)   // rasterised page
        let source = try makeFile("Recital.pdf", in: programsDir)    // retained source (sibling)
        let baked = try makeFile("event_program.pdf", in: programsDir)  // programPDFPath
        let orphan = try makeFile("ghost_p1.png", in: programsDir)   // from a deleted event
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.programImagePaths = [page]
        ev.programPDFPath = baked

        let removed = OrphanedMediaCleanup.sweep(events: [ev], photosDir: photosDir, audioDir: audioDir, programsDir: programsDir, clipsDir: clipsDir)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: page.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the retained source PDF for a referenced page must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
