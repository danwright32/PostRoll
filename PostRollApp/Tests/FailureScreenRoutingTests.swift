import XCTest

/// #257: a halt and a failure are different screens.
final class FailureScreenRoutingTests: XCTestCase {

    private func halted(_ reason: String) -> WeekGenerationResult {
        var week = WeekGenerationResult()
        week.stoppedReason = reason
        return week
    }

    func testARunThatHaltedGetsTheHaltScreen() {
        let screen = FailureScreen.resolve(
            message: "Claude usage limit reached",
            week: halted("Claude usage limit reached, resets at 3pm."))
        guard case .halted(let state) = screen else {
            return XCTFail("a capped week routed to the generic error screen, "
                           + "so the days that finished look lost and the only "
                           + "offer is to re-run everything")
        }
        XCTAssertEqual(state.reason, "Claude usage limit reached, resets at 3pm.")
    }

    func testAnOrdinaryFailureStillGetsTheErrorScreen() {
        // The halt screen offers to spend money. Showing it for an ordinary
        // crash would invite Dan to pay to retry something that was never a cap.
        XCTAssertEqual(
            FailureScreen.resolve(message: "ffmpeg not found", week: WeekGenerationResult()),
            .error("ffmpeg not found"))
    }

    func testAFailureWithNoWeekAtAllGetsTheErrorScreen() {
        XCTAssertEqual(FailureScreen.resolve(message: "boom", week: nil), .error("boom"))
    }

    func testABlankStopReasonDoesNotHijackEveryFailure() {
        // The generator writes the key on every save, so treating "present"
        // as "halted" would put the halt screen in front of every failure.
        XCTAssertEqual(FailureScreen.resolve(message: "boom", week: halted("  ")),
                       .error("boom"))
    }
}
