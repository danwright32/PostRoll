import XCTest

/// Re-linking photos that moved on disk has to move EVERY reference to them,
/// and the scan that reports missing files has to look at every referenced
/// file. Two P0s (#177, #178) came from the same 2026-08-01 event: a renamed
/// source folder left the collage layout and the B&W photo pointing at the old
/// location after a re-link, and the photo screen never reported the B&W photo
/// as missing in the first place.
final class MissingMediaTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func event() -> Event {
        Event(name: "Greatest Hits", org: "Org", venue: "Hall",
              date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
    }

    // MARK: - #177 rebinding carries standalone media

    func testRebindMovesTheStandaloneTuesdayMedia() {
        let oldRaw = url("/old/raw.jpg"), oldEdited = url("/old/edited.jpg")
        let oldBW = url("/old/bw.jpg"), oldRec = url("/old/screen.mov")
        let newRaw = url("/storage/raw.jpg"), newEdited = url("/storage/edited.jpg")
        let newBW = url("/storage/bw.jpg"), newRec = url("/storage/screen.mov")

        var day = PostingDay(day: .tuesday)
        day.rawPhotoPath = oldRaw
        day.editedPhotoPath = oldEdited
        day.bwPhotoPath = oldBW
        day.screenRecordingPath = oldRec

        let result = day.rebindingPhotos([oldRaw: newRaw, oldEdited: newEdited,
                                          oldBW: newBW, oldRec: newRec])

        XCTAssertEqual(result.rawPhotoPath, newRaw)
        XCTAssertEqual(result.editedPhotoPath, newEdited)
        XCTAssertEqual(result.bwPhotoPath, newBW)
        XCTAssertEqual(result.screenRecordingPath, newRec)
    }

    func testRemoveClearsTheStandaloneTuesdayMedia() {
        let bw = url("/old/bw.jpg"), raw = url("/old/raw.jpg")
        var day = PostingDay(day: .tuesday)
        day.rawPhotoPath = raw
        day.bwPhotoPath = bw

        let result = day.removingPhotos([bw])

        XCTAssertNil(result.bwPhotoPath, "the removed file must not stay referenced")
        XCTAssertEqual(result.rawPhotoPath, raw, "an untouched slot is left alone")
    }

    func testEventRelinkKeepsTheCollageLayoutPointingAtTheNewLocation() {
        let old = url("/old/a.jpg"), new = url("/storage/a.jpg")
        var wed = PostingDay(day: .wednesday)
        wed.photoPaths = [old]
        wed.collageCellOverride = [CollageCell(photoPath: old.path, x: 0, y: 0, w: 1, h: 1)]
        wed.collageCropOffsets = [old.absoluteString: CropOffset(x: 0, y: -1, scale: 1)]
        wed.reelCropOffsets = [old.absoluteString: CropOffset(x: 0, y: -0.5, scale: 1)]
        var tue = PostingDay(day: .tuesday)
        tue.bwPhotoPath = old

        var ev = event()
        ev.days["wednesday"] = wed
        ev.days["tuesday"] = tue
        ev.blogPhotoPaths = [old]

        let result = ev.rebindingPhotos([old: new])

        XCTAssertEqual(result.days["wednesday"]?.photoPaths, [new])
        XCTAssertEqual(result.days["wednesday"]?.collageCellOverride?.first?.photoPath, new.path,
                       "the collage layout has to move with the photo")
        XCTAssertNotNil(result.days["wednesday"]?.collageCropOffsets[new.absoluteString])
        XCTAssertNotNil(result.days["wednesday"]?.reelCropOffsets[new.absoluteString])
        XCTAssertEqual(result.days["tuesday"]?.bwPhotoPath, new,
                       "the B&W photo has no filename fallback, so it must be remapped")
        XCTAssertEqual(result.blogPhotoPaths, [new])
    }

    func testEventRemoveDropsEveryReferenceToTheMissingPhoto() {
        let gone = url("/old/a.jpg"), kept = url("/storage/b.jpg")
        var wed = PostingDay(day: .wednesday)
        wed.photoPaths = [gone, kept]
        wed.collageCellOverride = [CollageCell(photoPath: gone.path, x: 0, y: 0, w: 1, h: 1)]
        var tue = PostingDay(day: .tuesday)
        tue.bwPhotoPath = gone

        var ev = event()
        ev.days["wednesday"] = wed
        ev.days["tuesday"] = tue
        ev.blogPhotoPaths = [gone, kept]

        let result = ev.removingPhotos([gone])

        XCTAssertEqual(result.days["wednesday"]?.photoPaths, [kept])
        XCTAssertEqual(result.days["wednesday"]?.collageCellOverride, [])
        XCTAssertNil(result.days["tuesday"]?.bwPhotoPath)
        XCTAssertEqual(result.blogPhotoPaths, [kept])
    }

    // MARK: - #178 the scan sees the standalone media

    func testScanReportsASetButMissingBWPhoto() throws {
        let dir = try tempDir()
        let present = dir.appendingPathComponent("present.jpg")
        try Data("x".utf8).write(to: present)
        let absent = dir.appendingPathComponent("gone.jpg")

        var tue = PostingDay(day: .tuesday)
        tue.photoPaths = [present]
        tue.rawPhotoPath = present
        tue.bwPhotoPath = absent

        var ev = event()
        ev.days["tuesday"] = tue

        let result = MissingMediaScan.scan(ev)

        XCTAssertTrue(result.photos.isEmpty, "the day grid photo is on disk")
        XCTAssertEqual(result.standalone.map(\.url), [absent])
        XCTAssertEqual(result.standalone.first?.slot, .bwPhoto)
        XCTAssertEqual(result.standalone.first?.day, .tuesday)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.isEmpty)
    }

    func testScanReportsMissingDayPhotosAndStandaloneMediaTogether() throws {
        let dir = try tempDir()
        let goneGrid = dir.appendingPathComponent("grid.jpg")
        let goneEdited = dir.appendingPathComponent("edited.jpg")
        let goneRec = dir.appendingPathComponent("screen.mov")

        var tue = PostingDay(day: .tuesday)
        tue.photoPaths = [goneGrid]
        tue.editedPhotoPath = goneEdited
        tue.screenRecordingPath = goneRec

        var ev = event()
        ev.days["tuesday"] = tue

        let result = MissingMediaScan.scan(ev)

        XCTAssertEqual(result.photos, [goneGrid])
        XCTAssertEqual(Set(result.standalone.map(\.slot)), [.editedPhoto, .screenRecording])
        XCTAssertEqual(result.allURLs, [goneGrid, goneEdited, goneRec],
                       "the Locate flow re-links everything the scan flagged")
    }

    func testScanIgnoresUnsetSlots() throws {
        var ev = event()
        ev.days["tuesday"] = PostingDay(day: .tuesday)

        let result = MissingMediaScan.scan(ev)

        XCTAssertTrue(result.isEmpty, "an unset slot references nothing, so nothing is missing")
    }

    // MARK: - what the banner says

    func testBannerNamesTheStandaloneFilesRatherThanOnlyCountingThem() {
        let text = MissingMediaBannerText.message(
            photoCount: 3, standaloneNames: ["Tuesday B&W photo"])

        XCTAssertTrue(text.contains("3 photos"), text)
        XCTAssertTrue(text.contains("Tuesday B&W photo"),
                      "naming the slot points at the control to fix: \(text)")
    }

    func testBannerHandlesPhotosOnlyAndStandaloneOnly() {
        let photosOnly = MissingMediaBannerText.message(photoCount: 1, standaloneNames: [])
        XCTAssertTrue(photosOnly.contains("1 photo"), photosOnly)
        XCTAssertFalse(photosOnly.contains("1 photos"), photosOnly)

        let slotsOnly = MissingMediaBannerText.message(
            photoCount: 0, standaloneNames: ["Tuesday RAW photo", "Tuesday B&W photo"])
        XCTAssertFalse(slotsOnly.contains("0 photo"), slotsOnly)
        XCTAssertTrue(slotsOnly.contains("Tuesday RAW photo"), slotsOnly)
        XCTAssertTrue(slotsOnly.contains("Tuesday B&W photo"), slotsOnly)
    }

    // MARK: - helpers

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MissingMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
