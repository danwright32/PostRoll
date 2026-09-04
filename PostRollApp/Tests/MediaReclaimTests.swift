import XCTest

/// Originals picked from ~/Downloads/~/Desktop before the import-copy fix were
/// persisted as their external paths. macOS gates those folders per launch, so
/// the collage editor (which reloads a cell's image on every drag) re-triggered
/// the permission prompt on each action. MediaReclaim copies them into app
/// storage at launch and rewrites the paths, carrying crops/tags/cells along.
final class MediaReclaimTests: XCTestCase {

    private var storageRoot: URL!
    private var photosDir: URL!
    private var audioDir: URL!
    private var clipsDir: URL!
    private var external: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-\(UUID().uuidString)")
        storageRoot = base.appendingPathComponent("storage")
        photosDir = storageRoot.appendingPathComponent("photos")
        audioDir = storageRoot.appendingPathComponent("audio")
        clipsDir = storageRoot.appendingPathComponent("clips")
        external = base.appendingPathComponent("Downloads") // stand-in for a gated folder
        for dir in [photosDir!, audioDir!, clipsDir!, external!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storageRoot.deletingLastPathComponent())
    }

    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func reclaim(_ events: inout [Event]) -> Bool {
        MediaReclaim.reclaim(events: &events, photosDir: photosDir, audioDir: audioDir, clipsDir: clipsDir, storageRoot: storageRoot).changed
    }

    func testExternalPhotoIsCopiedInAndPathRewritten() throws {
        let ext = try makeFile("shot.jpg", in: external)
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [ext]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["wednesday"] = day
        var events = [ev]

        XCTAssertTrue(reclaim(&events))

        let newPath = events[0].days["wednesday"]!.photoPaths[0]
        XCTAssertTrue(AppPaths.isInside(newPath, root: storageRoot),
                      "External photo must be rewritten to a path inside app storage.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath.path),
                      "The copy must actually exist on disk.")
    }

    func testCropsTagsAndCollageCellsFollowTheNewPath() throws {
        let ext = try makeFile("shot.jpg", in: external)
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [ext]
        day.collageCropOffsets = [ext.absoluteString: CropOffset(x: 0.25, y: 0.5)]
        day.photoTags = [ext.absoluteString: ["Jane Doe"]]
        day.collageCellOverride = [CollageCell(photoPath: ext.path, x: 0, y: 0, w: 1080, h: 1920)]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["wednesday"] = day
        var events = [ev]

        _ = reclaim(&events)

        let pd = events[0].days["wednesday"]!
        let newURL = pd.photoPaths[0]
        XCTAssertEqual(pd.collageCropOffsets[newURL.absoluteString]?.x, 0.25,
                       "Collage crop must re-key to the new URL.")
        XCTAssertEqual(pd.photoTags[newURL.absoluteString], ["Jane Doe"],
                       "Per-photo tags must re-key to the new URL.")
        XCTAssertEqual(pd.collageCellOverride?.first?.photoPath, newURL.path,
                       "The collage cell must point at the new path so its image read is ungated.")
    }

    func testSpecialMediaFieldsAreReclaimed() throws {
        let video = try makeFile("rec.mov", in: external)
        let audio = try makeFile("song.m4a", in: external)
        var day = PostingDay(day: .tuesday)
        day.screenRecordingPath = video
        day.audioPath = audio
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["tuesday"] = day
        var events = [ev]

        _ = reclaim(&events)

        let pd = events[0].days["tuesday"]!
        XCTAssertTrue(AppPaths.isInside(pd.screenRecordingPath!, root: storageRoot))
        XCTAssertTrue(AppPaths.isInside(pd.audioPath!, root: storageRoot),
                      "Audio must land in the audio dir inside storage.")
        XCTAssertTrue(AppPaths.isInside(pd.audioPath!, root: audioDir))
    }

    // Friday auto-cut clip reel (#131): imported clips must land in the clips
    // dir (not photosDir) and carry the AI plan + user override entries to the
    // new path, same as photoPaths carries crops/tags/collage cells.
    func testClipPathsAreReclaimedAndPlanOverrideFollowTheNewPath() throws {
        let ext = try makeFile("show.mov", in: external)
        var day = PostingDay(day: .friday)
        day.clipPaths = [ext]
        day.fridayClipPlan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: ext.path, trimIn: 1, trimOut: 6, transition: .cut)],
            rationale: "opens strong"
        )
        day.fridayClipOverride = [
            ReelClipOverride(clipPath: ext.path, order: 0, included: true, trimIn: 1, trimOut: 6)
        ]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["friday"] = day
        var events = [ev]

        XCTAssertTrue(reclaim(&events))

        let pd = events[0].days["friday"]!
        let newURL = pd.clipPaths[0]
        XCTAssertTrue(AppPaths.isInside(newURL, root: clipsDir), "Clip must land in the clips dir, not photosDir.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(pd.fridayClipPlan?.selections.first?.clipPath, newURL.path,
                       "The AI plan must point at the new path so playback/edit reads are ungated.")
        XCTAssertEqual(pd.fridayClipOverride?.first?.clipPath, newURL.path,
                       "The user's manual override must follow the clip to its new path.")
    }

    func testAlreadyInStorageIsUntouchedAndIdempotent() throws {
        let inside = try makeFile("kept.jpg", in: photosDir)
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [inside]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["wednesday"] = day
        var events = [ev]

        XCTAssertFalse(reclaim(&events), "Paths already inside storage must not be reported as changed.")
        XCTAssertEqual(events[0].days["wednesday"]!.photoPaths, [inside])
    }

    func testMissingExternalFileKeepsItsPath() throws {
        // Original already gone from disk: nothing to copy, leave the path for
        // the missing-photo flow to surface.
        let gone = external.appendingPathComponent("vanished.jpg")
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [gone]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["wednesday"] = day
        var events = [ev]

        XCTAssertFalse(reclaim(&events))
        XCTAssertEqual(events[0].days["wednesday"]!.photoPaths, [gone])
    }

    // MARK: - What a source that is gone costs (#971)

    func testAMissingSourceIsNotAttemptedAsACopy() throws {
        // Measured on the live store: 1,514 stored paths point at files that
        // are no longer there, and every cold launch paid a createDirectory, a
        // destination check, a doomed copyItem and an NSLog for each of them,
        // on the main thread before the first frame.
        //
        // A source that is not there is not a copy that FAILED, it is a file
        // the missing-media flow owns, and the two need telling apart (L11).
        let neverMade = storageRoot.appendingPathComponent("not-made-yet")
        let gone = external.appendingPathComponent("vanished.jpg")

        let result = AppPaths.importedCopyResult(of: gone, into: neverMade,
                                                 storageRoot: storageRoot)

        guard case .failure(let why) = result else {
            return XCTFail("a source that is not there cannot have been copied")
        }
        XCTAssertTrue(why.sourceIsMissing,
                      "a file that is gone reports as an ordinary copy failure, "
                      + "so nothing downstream can tell it from a permission "
                      + "problem or a full disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: neverMade.path),
                       "the copy was attempted anyway: the destination folder "
                       + "was created, which is the work this exists to skip")
    }

    func testARealCopyFailureIsStillReportedAsOne() throws {
        // The positive control (L159). Without it, "missing sources are told
        // apart" is satisfied by marking every failure that way.
        let source = try makeFile("real.jpg", in: external)
        let intoAFile = try makeFile("in-the-way", in: storageRoot)

        let result = AppPaths.importedCopyResult(of: source, into: intoAFile,
                                                 storageRoot: storageRoot)

        guard case .failure(let why) = result else {
            return XCTFail("copying into a file rather than a folder cannot succeed")
        }
        XCTAssertFalse(why.sourceIsMissing,
                       "a source that is right there was reported as missing")
    }

    func testTheReclaimSaysHowManyReferencesItCouldNotReach() throws {
        // A repair that can never succeed, retried forever and saying nothing,
        // is indistinguishable from one with nothing to do (L98, L47). The
        // count is what tells them apart.
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [external.appendingPathComponent("gone-one.jpg"),
                          external.appendingPathComponent("gone-two.jpg"),
                          try makeFile("here.jpg", in: external)]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(),
                       shootType: .fullShow)
        ev.days["wednesday"] = day
        var events = [ev]

        let outcome = MediaReclaim.reclaim(
            events: &events, photosDir: photosDir, audioDir: audioDir,
            clipsDir: clipsDir, storageRoot: storageRoot)

        XCTAssertEqual(outcome.unreachable, 2)
        XCTAssertTrue(outcome.changed, "the one file that is there was still moved")
    }

    func testAStoreWithNothingMissingReportsNone() throws {
        // The other direction, or the count above is satisfied by one that
        // always answers with something (L98).
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [try makeFile("here.jpg", in: external)]
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(),
                       shootType: .fullShow)
        ev.days["wednesday"] = day
        var events = [ev]

        XCTAssertEqual(MediaReclaim.reclaim(
            events: &events, photosDir: photosDir, audioDir: audioDir,
            clipsDir: clipsDir, storageRoot: storageRoot).unreachable, 0)
    }

    func testTheSecondLaunchReallyIsANoOpOnAStoreFullOfDeadReferences() throws {
        // The doc comment claimed the second launch is a no-op and nothing
        // checked it, which on real data it was not: every dead reference was
        // re-attempted every launch (L32).
        var day = PostingDay(day: .wednesday)
        day.photoPaths = (0..<5).map {
            external.appendingPathComponent("gone-\($0).jpg")
        }
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(),
                       shootType: .fullShow)
        ev.days["wednesday"] = day
        var events = [ev]

        let first = MediaReclaim.reclaim(
            events: &events, photosDir: photosDir, audioDir: audioDir,
            clipsDir: clipsDir, storageRoot: storageRoot)
        let second = MediaReclaim.reclaim(
            events: &events, photosDir: photosDir, audioDir: audioDir,
            clipsDir: clipsDir, storageRoot: storageRoot)

        XCTAssertFalse(first.changed, "nothing could be moved")
        XCTAssertFalse(second.changed, "so nothing is written on either launch")
        XCTAssertEqual(second.unreachable, 5,
                       "and the second launch still SAYS what it could not "
                       + "reach, rather than going quiet about it")
    }
}
