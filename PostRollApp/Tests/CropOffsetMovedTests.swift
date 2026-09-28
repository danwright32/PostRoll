import XCTest

/// Whether a crop was moved is asked of the real default, not of zero.
///
/// The default framing has been top anchored (y = -1) since #167, while five
/// places kept asking `x != 0 || y != 0`, so every untouched photo counted as
/// moved: the editor drew its "adjusted" dot on every cell, and every untouched
/// collage and reel day sent Python a crop list. The renders were right only
/// because Python's own default is top anchored too. Found 2026-09-28 while
/// building the reel's removal mode.
final class CropOffsetMovedTests: XCTestCase {

    func testTheDefaultIsNotMoved() {
        XCTAssertFalse(CropOffset().isMoved)
        XCTAssertFalse(CropOffset.isMoved([0, -1, 1]))
    }

    func testCentringAPhotoIsAMove() {
        // Zero is a real position now: the photo dragged to its centre.
        XCTAssertTrue(CropOffset(x: 0, y: 0, scale: 1).isMoved)
        XCTAssertTrue(CropOffset.isMoved([0, 0, 1]))
        XCTAssertTrue(CropOffset(x: 0, y: -1, scale: 1.3).isMoved)
    }

    func testAnUntouchedCollageDaySendsNoCrops() async throws {
        var event = Event(name: "Gala", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_800_000_000),
                          shootType: .fullShow)
        var pd = PostingDay(day: .wednesday)
        let a = URL(fileURLWithPath: "/p/a.jpg")
        pd.photoPaths = [a, URL(fileURLWithPath: "/p/b.jpg")]
        pd.collageCropOffsets = [a.absoluteString: CropOffset()]
        event.days[DayName.wednesday.rawValue] = pd
        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)
        let days = try XCTUnwrap(manifest["days"] as? [String: Any])
        let day = try XCTUnwrap(days["wednesday"] as? [String: Any])
        XCTAssertNil(day["crop_offsets"])
    }

    func testTheOptionsRendererIsNotHandedDefaultCrops() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("crop-moved-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try PythonBridge.cropOffsetsArgument(
            offsets: [[0, -1, 1], [0, -1, 1]], writingTo: file), [])
        XCTAssertFalse(try PythonBridge.cropOffsetsArgument(
            offsets: [[0, -1, 1], [0, 0, 1]], writingTo: file).isEmpty)
    }
}
