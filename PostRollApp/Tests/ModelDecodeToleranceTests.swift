import XCTest

/// Pins the decodeIfPresent contract (issue #2): every persisted Codable
/// struct must tolerate missing keys, or the next schema change makes the
/// whole events.json (or analytics.json) undecodable, and the wipe
/// protection path kicks in where ordinary loading should have worked.
final class ModelDecodeToleranceTests: XCTestCase {

    func testOCRResultToleratesMissingKeys() throws {
        let json = Data(#"{"performers": [{"name": "Jo"}]}"#.utf8)
        let ocr = try JSONDecoder().decode(OCRResult.self, from: json)
        XCTAssertEqual(ocr.performers.count, 1)
        XCTAssertEqual(ocr.performers[0].name, "Jo")
        XCTAssertTrue(ocr.pieces.isEmpty)
        XCTAssertTrue(ocr.scenes.isEmpty)
        XCTAssertEqual(ocr.programNotes, "")
    }

    func testCollageCellToleratesMissingKeys() throws {
        let json = Data(#"{"photo_path": "/x.jpg", "x": 1, "y": 2}"#.utf8)
        let cell = try JSONDecoder().decode(CollageCell.self, from: json)
        XCTAssertEqual(cell.photoPath, "/x.jpg")
        XCTAssertEqual(cell.w, 0)
        XCTAssertEqual(cell.h, 0)
    }

    func testIGPostToleratesMissingKeysAndUnknownMediaType() throws {
        // A new Meta post type must degrade to .unknown, not poison the
        // decode of the entire analytics file.
        let json = Data(#"{"ig_post_id": "123", "media_type": "broadcast_channel"}"#.utf8)
        let post = try JSONDecoder().decode(IGPost.self, from: json)
        XCTAssertEqual(post.igPostID, "123")
        XCTAssertEqual(post.mediaType, .unknown)
        XCTAssertFalse(post.isPersonal)
        XCTAssertEqual(post.caption, "")
        XCTAssertNil(post.views)
    }

    func testEventRoundTripPreservesIdentity() throws {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        event.ocrResult = OCRResult(performers: [Performer(name: "Jo", role: "actor")])
        let encoded = try JSONEncoder().encode([event])
        let decoded = try JSONDecoder().decode([Event].self, from: encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, event.id)
        XCTAssertEqual(decoded[0].ocrResult?.performers.first?.name, "Jo")
    }
}
