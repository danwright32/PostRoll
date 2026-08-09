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

    // Phase 3 (#134): duck gain / mute are new fields on an already-shipped
    // struct: an event saved before this feature existed has neither key
    // in its JSON at all. Must default to -15dB unducked, not muted.
    func testPostingDayToleratesMissingAudioDuckFields() throws {
        let json = Data(#"{"day": "friday", "photoPaths": []}"#.utf8)
        let day = try JSONDecoder().decode(PostingDay.self, from: json)
        XCTAssertEqual(day.fridayAudioDuckDB, -15.0)
        XCTAssertFalse(day.fridayAudioMuted)
    }

    // Title card overlay (plan #148, Phase 3): on by default (Dan's call,
    // 2026-07-09), so an event saved before this feature existed, with no
    // key at all, must decode as NOT muted (title card shows).
    func testPostingDayToleratesMissingTitleCardMutedField() throws {
        let json = Data(#"{"day": "friday", "photoPaths": []}"#.utf8)
        let day = try JSONDecoder().decode(PostingDay.self, from: json)
        XCTAssertFalse(day.titleCardMuted)
    }

    func testReelClipOverrideToleratesMissingKeys() throws {
        let json = Data(#"{"clip_path": "/x.mov"}"#.utf8)
        let override = try JSONDecoder().decode(ReelClipOverride.self, from: json)
        XCTAssertEqual(override.clipPath, "/x.mov")
        XCTAssertEqual(override.order, 0)
        XCTAssertTrue(override.included)
        XCTAssertEqual(override.trimIn, 0)
        XCTAssertEqual(override.trimOut, 0)
        XCTAssertEqual(override.cropX, 0)
        XCTAssertEqual(override.cropY, 0)
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
        XCTAssertEqual(selection.cropX, 0)
        XCTAssertEqual(selection.cropY, 0)
        XCTAssertEqual(selection.cropConfidence, "low")
    }

    // Per-shot crop (plan #148, Phase 2): Python's snake_case crop fields
    // must decode onto the Swift camelCase properties.
    func testFridayClipSelectionDecodesCropFieldsFromPython() throws {
        let json = Data(#"{"clip_path": "/x.mov", "crop_x": 0.4, "crop_y": -0.25, "crop_confidence": "high"}"#.utf8)
        let selection = try JSONDecoder().decode(FridayClipSelection.self, from: json)
        XCTAssertEqual(selection.cropX, 0.4)
        XCTAssertEqual(selection.cropY, -0.25)
        XCTAssertEqual(selection.cropConfidence, "high")
    }

    // Instagram grid cover images (#139/#140): a PostingDay saved by a build
    // before this feature existed has neither coverPick nor coverOverride in
    // its JSON at all. Decoding must default them safely, not throw and trip
    // the events.json wipe-protection path.
    func testPostingDayToleratesMissingCoverFields() throws {
        let json = Data(#"{"day": "thursday", "photoPaths": []}"#.utf8)
        let day = try JSONDecoder().decode(PostingDay.self, from: json)
        XCTAssertNil(day.coverPick)
        XCTAssertNil(day.coverOverride)
    }

    func testCoverPickToleratesMissingKeys() throws {
        let json = Data(#"{}"#.utf8)
        let pick = try JSONDecoder().decode(CoverPick.self, from: json)
        XCTAssertEqual(pick.sourcePath, "")
        XCTAssertEqual(pick.rationale, "")
    }
}

/// generate_week.py now writes two extra keys alongside the day captions,
/// `complete` and `stopped_reason`, so a run stopped by a usage cap can be told
/// apart from a finished one (#206). Swift must keep decoding the payload while
/// it ignores them, and must not mistake a partial week for a whole one.
final class WeekResultPartialRunDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> WeekGenerationResult {
        try JSONDecoder().decode(WeekGenerationResult.self, from: Data(json.utf8))
    }

    func testTheNewRunStatusKeysDoNotBreakDecoding() throws {
        let result = try decode("""
        {"sunday": {"caption": "s"}, "monday": null, "errors": {},
         "complete": false, "stopped_reason": "usage limit reached"}
        """)

        XCTAssertEqual(result.sunday?.caption, "s")
        XCTAssertNil(result.monday)
    }

    func testAPartialWeekStillCarriesTheDaysThatFinished() throws {
        // What a run stopped at Tuesday leaves on disk. The days already
        // generated were paid for and must survive the stop.
        let result = try decode("""
        {"sunday": {"caption": "s"}, "monday": {"caption": "m"},
         "errors": {}, "complete": false, "stopped_reason": "usage limit reached"}
        """)

        XCTAssertEqual(result.sunday?.caption, "s")
        XCTAssertEqual(result.monday?.caption, "m")
        XCTAssertNil(result.tuesday, "the day it stopped on has no caption")
        XCTAssertTrue(result.errors.isEmpty, "a stop is not a per-day failure")
    }
}

/// generate_blog.py returns a `findings` list: the deterministic blog checks
/// from #201 (invented number, alt text too long, a performer grouped by
/// gender). They were reaching stderr and the Python result but never Dan's
/// screen, because BlogOutput only decodes the keys it declares, so the whole
/// enforcement pass was invisible in the app.
final class BlogFindingsDecodeTests: XCTestCase {

    func testFindingsDecodeFromThePythonPayload() throws {
        let json = Data("""
        {"title": "T", "body": "B", "photo_count": 2,
         "findings": [
           {"code": "invented_number",
            "message": "No count in the source data means no number in the post.",
            "detail": "'thirty' does not appear in the program data"}
         ]}
        """.utf8)

        let blog = try JSONDecoder().decode(BlogOutput.self, from: json)

        XCTAssertEqual(blog.findings.count, 1)
        XCTAssertEqual(blog.findings[0].code, "invented_number")
        XCTAssertTrue(blog.findings[0].detail.contains("thirty"))
    }

    func testABlogSavedBeforeFindingsExistedStillDecodes() throws {
        let json = Data(#"{"title": "T", "body": "B"}"#.utf8)
        let blog = try JSONDecoder().decode(BlogOutput.self, from: json)
        XCTAssertTrue(blog.findings.isEmpty)
    }

    func testFindingsSurviveASaveAndReload() throws {
        // They are stored on the event, so a finding must still be on screen
        // after the app is relaunched, not only in the run that produced it.
        var blog = BlogOutput(title: "T", body: "B")
        blog.findings = [BlogFinding(code: "alt_text_length",
                                     message: "Alt text must be 15 to 25 words.",
                                     detail: "a.jpg: 34 words.")]

        let round = try JSONDecoder().decode(
            BlogOutput.self, from: try JSONEncoder().encode(blog))

        XCTAssertEqual(round.findings.first?.code, "alt_text_length")
    }
}
