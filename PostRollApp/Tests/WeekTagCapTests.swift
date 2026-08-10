import XCTest

/// #281: the week tag list stops at what Instagram accepts, and says what fell off.
///
/// `weekTagList` gathered every handle taggable anywhere in the week with no
/// ceiling. Instagram tags at most 20 accounts on one post, so past 20 the
/// extra handles are simply not tagged when the list is pasted in, and nothing
/// in the app or in CAPTIONS.txt said which ones. The export reads as complete
/// either way, which is the same silent partial failure as #221 and #222, and a
/// week at a multi-ensemble venue clears 20 taggable accounts in normal use.
///
/// `tests/fixtures/caption_blocks.json` is the contract. `tests/
/// test_week_tag_cap.py` asserts the Python side satisfies the same file.
final class WeekTagCapTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Day: Decodable {
            let tag_handles: [String]
            let photos: [String]
            let photo_tags: [String: [String]]
        }
        struct Case: Decodable {
            let _what: String
            let days: [Day]
            let kept: [String]
            let dropped: [String]
        }
        let max_tags_per_post: Int
        let dropped_header: String
        let cases: [Case]
    }

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/caption_blocks.json"))
    }

    /// An event carrying the fixture's days, one fixture day per posting day.
    private func event(from days: [Fixture.Day]) -> Event {
        var event = Event(name: "E", org: "O", venue: "V", date: Date(), shootType: .fullShow)
        for (index, day) in days.enumerated() {
            let name = DayName.allCases[index]
            var posting = PostingDay(day: name)
            posting.tagHandles = day.tag_handles
            posting.photoPaths = day.photos.map { URL(fileURLWithPath: "/p/\($0)") }
            var tags: [String: [String]] = [:]
            for (photo, handles) in day.photo_tags {
                tags[URL(fileURLWithPath: "/p/\(photo)").absoluteString] = handles
            }
            posting.photoTags = tags
            event.days[name.rawValue] = posting
        }
        return event
    }

    func testTheCapIsTheNumberTheContractStates() throws {
        XCTAssertEqual(CaptionBlocks.maxTagsPerPost, try loadFixture().max_tags_per_post)
    }

    func testTheDroppedHeaderIsTheOneTheContractStates() throws {
        XCTAssertEqual(CaptionBlocks.tagsDroppedHeader, try loadFixture().dropped_header)
    }

    func testSwiftSatisfiesTheSharedTagContract() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 6,
                                    "a gutted fixture would pass vacuously")

        for c in fixture.cases {
            let result = CaptionBlocks.weekTags(event: event(from: c.days))
            XCTAssertEqual(result.kept, c.kept, c._what)
            XCTAssertEqual(result.dropped, c.dropped, c._what)
        }
    }

    func testNothingIsKeptPastTheCapWhateverTheInput() {
        var event = Event(name: "E", org: "O", venue: "V", date: Date(), shootType: .fullShow)
        var day = PostingDay(day: .sunday)
        day.tagHandles = (0..<60).map { String(format: "h%03d", $0) }
        event.days[DayName.sunday.rawValue] = day

        let result = CaptionBlocks.weekTags(event: event)

        XCTAssertEqual(result.kept.count, CaptionBlocks.maxTagsPerPost)
        XCTAssertEqual(result.dropped.count, 60 - CaptionBlocks.maxTagsPerPost)
        XCTAssertTrue(Set(result.kept).isDisjoint(with: result.dropped))
    }

    func testEveryHandleIsAccountedForSomewhere() {
        // The whole point: what falls off has to be nameable. A handle that is
        // neither kept nor reported is exactly the silent loss this closes.
        var event = Event(name: "E", org: "O", venue: "V", date: Date(), shootType: .fullShow)
        var day = PostingDay(day: .sunday)
        day.tagHandles = (0..<35).map { String(format: "h%03d", $0) }
        event.days[DayName.sunday.rawValue] = day

        let result = CaptionBlocks.weekTags(event: event)

        XCTAssertEqual(result.kept.count + result.dropped.count, 35)
    }

    func testTheOldEntryPointStillReturnsWhatFits() {
        // weekTagList is what the export calls for the TAG LIST block itself,
        // so it must be the capped list, not the raw one.
        var event = Event(name: "E", org: "O", venue: "V", date: Date(), shootType: .fullShow)
        var day = PostingDay(day: .sunday)
        day.tagHandles = (0..<40).map { String(format: "h%03d", $0) }
        event.days[DayName.sunday.rawValue] = day

        XCTAssertEqual(CaptionBlocks.weekTagList(event: event).count,
                       CaptionBlocks.maxTagsPerPost)
    }
}
