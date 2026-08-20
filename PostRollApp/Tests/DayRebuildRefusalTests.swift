import XCTest

/// A day already rebuilding does not get a second run (#728).
///
/// `beginDayRegen` returns false when a day is already rebuilding, and says in
/// its own comment why that matters: two runs are two subprocesses writing one
/// MP4. Four of the five callers on the caption review screen ignored the
/// answer, and each of them persists something before the render, so honouring
/// it late is no better than ignoring it: the event carries new photos, a new
/// seed or a cleared audio track, and nothing is rendered to match.
final class DayRebuildRefusalTests: XCTestCase {

    func testItNamesTheDayAndSaysNothingWasChanged() throws {
        let message = try XCTUnwrap(DayRebuildRefusal.message(for: [.wednesday]))

        XCTAssertTrue(message.contains("Wednesday"),
                      "the refusal does not say which day is busy: \(message)")
        // The action's own write is deliberately not made, and that is the part
        // Dan cannot see for himself: his photo pick simply did not land.
        XCTAssertTrue(message.lowercased().contains("nothing was changed"),
                      "the refusal does not say the change did not happen: \(message)")
    }

    func testItReadsAsOneSentencePerNumberOfDays() throws {
        let one = try XCTUnwrap(DayRebuildRefusal.message(for: [.friday]))
        let two = try XCTUnwrap(DayRebuildRefusal.message(for: [.tuesday, .friday]))

        XCTAssertTrue(one.contains("is still rebuilding"), one)
        XCTAssertTrue(two.contains("are still rebuilding"), two)
        XCTAssertTrue(two.contains("Tuesday") && two.contains("Friday"), two)
    }

    func testTheDaysAreNamedInTheWeeksOwnOrder() throws {
        // Given in the other order on purpose: two refusals about the same two
        // days must read identically, or they look like different problems.
        let message = try XCTUnwrap(DayRebuildRefusal.message(for: [.friday, .tuesday]))
        let tuesday = try XCTUnwrap(message.range(of: "Tuesday"))
        let friday = try XCTUnwrap(message.range(of: "Friday"))
        XCTAssertTrue(tuesday.lowerBound < friday.lowerBound, message)
    }

    func testNoDaysIsNoMessageRatherThanAnEmptyBanner() {
        // A message about nothing would render an empty red row, which claims a
        // problem it cannot describe (L11).
        XCTAssertNil(DayRebuildRefusal.message(for: []))
    }
}
