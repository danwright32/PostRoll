import XCTest

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
