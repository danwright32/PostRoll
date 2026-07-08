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

    // Friday auto-cut clip reel (#131): a PostingDay saved by a build before
    // this feature existed has none of clipPaths/fridayClipPlan/
    // fridayClipOverride in its JSON at all. Decoding must default them
    // safely, not throw and trip the events.json wipe-protection path.
    func testPostingDayToleratesMissingClipFields() throws {
        let json = Data(#"{"day": "friday", "photoPaths": []}"#.utf8)
        let day = try JSONDecoder().decode(PostingDay.self, from: json)
        XCTAssertTrue(day.clipPaths.isEmpty)
        XCTAssertNil(day.fridayClipPlan)
        XCTAssertNil(day.fridayClipOverride)
    }

    func testReelClipOverrideToleratesMissingKeys() throws {
        let json = Data(#"{"clip_path": "/x.mov"}"#.utf8)
        let override = try JSONDecoder().decode(ReelClipOverride.self, from: json)
        XCTAssertEqual(override.clipPath, "/x.mov")
        XCTAssertEqual(override.order, 0)
        XCTAssertTrue(override.included)
        XCTAssertEqual(override.trimIn, 0)
        XCTAssertEqual(override.trimOut, 0)
    }

    func testFridayClipPlanToleratesMissingKeys() throws {
        let json = Data(#"{}"#.utf8)
        let plan = try JSONDecoder().decode(FridayClipPlan.self, from: json)
        XCTAssertTrue(plan.selections.isEmpty)
        XCTAssertEqual(plan.rationale, "")
    }

    func testFridayClipSelectionToleratesMissingKeys() throws {
        let json = Data(#"{"clip_path": "/x.mov"}"#.utf8)
        let selection = try JSONDecoder().decode(FridayClipSelection.self, from: json)
        XCTAssertEqual(selection.clipPath, "/x.mov")
        XCTAssertEqual(selection.trimIn, 0)
        XCTAssertEqual(selection.trimOut, 0)
        XCTAssertEqual(selection.transition, .cut)
    }
}
