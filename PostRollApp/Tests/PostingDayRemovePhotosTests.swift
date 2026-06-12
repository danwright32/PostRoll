import XCTest

/// PostingDay.removingPhotos drops dead photo references and every per-photo
/// entry that pointed at them. A missed map leaves an orphan crop/tag keyed to
/// a photo that's no longer there, so each is pinned.
final class PostingDayRemovePhotosTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/photos/\(name)") }

    func testRemovesPhotosAndTheirCropsAndTags() {
        let a = url("a.jpg"), b = url("b.jpg"), c = url("c.jpg")
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [a, b, c]
        day.cropOffsets = [a.absoluteString: CropOffset(x: 0.5, y: 0, scale: 1),
                           b.absoluteString: CropOffset(x: 0, y: 0.3, scale: 1)]
        day.photoTags = [a.absoluteString: ["Mike"], c.absoluteString: ["Jane"]]

        let result = day.removingPhotos([a, b])

        XCTAssertEqual(result.photoPaths, [c])
        XCTAssertNil(result.cropOffsets[a.absoluteString])
        XCTAssertNil(result.cropOffsets[b.absoluteString])
        XCTAssertNil(result.photoTags[a.absoluteString])
        XCTAssertEqual(result.photoTags[c.absoluteString], ["Jane"], "surviving photo's tags kept")
    }

    func testRemovesCollageCellsForMissingPhotos() {
        let a = url("a.jpg"), b = url("b.jpg")
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [a, b]
        day.collageCellOverride = [
            CollageCell(photoPath: a.path, x: 0, y: 0, w: 1, h: 1),
            CollageCell(photoPath: b.path, x: 1, y: 0, w: 1, h: 1),
        ]

        let result = day.removingPhotos([a])

        XCTAssertEqual(result.collageCellOverride?.map(\.photoPath), [b.path])
    }

    func testEmptyRemovalIsNoOp() {
        let a = url("a.jpg")
        var day = PostingDay(day: .sunday)
        day.photoPaths = [a]
        day.photoTags = [a.absoluteString: ["Mike"]]

        let result = day.removingPhotos([])

        XCTAssertEqual(result.photoPaths, [a])
        XCTAssertEqual(result.photoTags[a.absoluteString], ["Mike"])
    }

    func testRebindCarriesCropsTagsAndCollageToNewURL() {
        let old = url("old/a.jpg"), b = url("b.jpg")
        let new = URL(fileURLWithPath: "/storage/a.jpg")
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [old, b]
        day.cropOffsets = [old.absoluteString: CropOffset(x: 0.4, y: 0, scale: 1)]
        day.photoTags = [old.absoluteString: ["Mike"]]
        day.collageCellOverride = [CollageCell(photoPath: old.path, x: 0, y: 0, w: 1, h: 1)]

        let result = day.rebindingPhotos([old: new])

        XCTAssertEqual(result.photoPaths, [new, b], "URL swapped in place, order kept")
        XCTAssertEqual(result.cropOffsets[new.absoluteString]?.x, 0.4)
        XCTAssertNil(result.cropOffsets[old.absoluteString])
        XCTAssertEqual(result.photoTags[new.absoluteString], ["Mike"])
        XCTAssertEqual(result.collageCellOverride?.first?.photoPath, new.path)
    }

    func testRebindEmptyIsNoOp() {
        let a = url("a.jpg")
        var day = PostingDay(day: .sunday)
        day.photoPaths = [a]
        XCTAssertEqual(day.rebindingPhotos([:]).photoPaths, [a])
    }
}
