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

    // MARK: - What a granted rebuild takes back (#731)

    func testAGrantedRebuildClearsTheRefusalThatSaidTheDayWasBusy() {
        let after = DayRebuildRefusal.afterRebuildGranted(
            action: nil, rebuild: "Friday is still rebuilding, so nothing was changed.")

        XCTAssertNil(after.rebuild,
                     "the day is being rebuilt now, so the message saying it was "
                     + "already rebuilding is no longer true and must not sit there")
    }

    func testAGrantedRebuildLeavesAnUnrelatedRefusalAlone() {
        // The half that was wrong first time round. importFridayClips reports
        // which picks failed to copy and THEN rebuilds with the ones that
        // landed, so clearing everything on the grant erased the only report of
        // the failed half, in the same click that produced it (L47).
        let copyFailure = "2 of 5 clips could not be copied, so they were left out."
        let after = DayRebuildRefusal.afterRebuildGranted(
            action: copyFailure,
            rebuild: "Friday is still rebuilding, so nothing was changed.")

        XCTAssertEqual(after.action, copyFailure,
                       "a rebuild starting says nothing about a file that would "
                       + "not copy, so it must not take that message away")
        XCTAssertNil(after.rebuild)
    }

    func testAGrantWithNothingRefusedChangesNothing() {
        let after = DayRebuildRefusal.afterRebuildGranted(action: nil, rebuild: nil)
        XCTAssertNil(after.action)
        XCTAssertNil(after.rebuild)
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
