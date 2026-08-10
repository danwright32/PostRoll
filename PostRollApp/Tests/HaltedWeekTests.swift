import XCTest

/// #257: a week that stopped at a usage cap is its own state, with a way out.
///
/// `generate_week` writes `stopped_reason` on every halt and saves everything
/// finished up to that point. Nothing read it, so the halt worked, the partial
/// week survived, and the reason it stopped never reached Dan.
///
/// A halted week is not a failed week and not a finished one. It has work in it
/// worth keeping, and exactly two ways forward: wait for the allowance to reset,
/// or spend money to finish now. Nothing is spent without Dan saying so, so the
/// paid route is an explicit action that states its own cost.
final class HaltedWeekTests: XCTestCase {

    private func result(stoppedReason: String?, days: [DayName] = []) -> WeekGenerationResult {
        var week = WeekGenerationResult()
        week.stoppedReason = stoppedReason
        for day in days {
            week[day] = DayCaption(caption: "a caption for \(day.rawValue)")
        }
        return week
    }

    // ── the state ─────────────────────────────────────────────────────────────

    func testAWeekWithNoStopReasonIsNotHalted() {
        XCTAssertNil(HaltedWeek.from(result(stoppedReason: nil)))
        XCTAssertNil(HaltedWeek.from(result(stoppedReason: "")))
        XCTAssertNil(HaltedWeek.from(result(stoppedReason: "   ")))
    }

    func testAHaltedWeekReportsWhyItStopped() {
        let halted = HaltedWeek.from(result(
            stoppedReason: "Claude usage limit reached, resets at 3pm. Everything generated so far is saved."))
        XCTAssertEqual(
            halted?.reason,
            "Claude usage limit reached, resets at 3pm. Everything generated so far is saved.")
    }

    func testItReportsWhatSurvivedSoTheWorkDoesNotLookLost() {
        // The whole point of halting rather than failing is that the finished
        // days are kept. A screen that only says "stopped" hides that.
        let halted = HaltedWeek.from(result(
            stoppedReason: "Claude usage limit reached",
            days: [.sunday, .monday, .tuesday]))
        XCTAssertEqual(halted?.finishedDays, [.sunday, .monday, .tuesday])
    }

    func testAHaltBeforeAnythingFinishedIsStillAHalt() {
        // Zero finished days is an empty state, not an error state, and it must
        // not be mistaken for "no halt happened".
        let halted = HaltedWeek.from(result(stoppedReason: "Claude usage limit reached"))
        XCTAssertNotNil(halted)
        XCTAssertTrue(halted?.finishedDays.isEmpty == true)
    }

    // ── the two ways out ──────────────────────────────────────────────────────

    func testBothRoutesForwardAreOffered() {
        // A halted run with no route forward leaves Dan re-running the whole
        // week by hand, throwing away everything that did finish.
        let halted = HaltedWeek.from(result(stoppedReason: "Claude usage limit reached"))
        XCTAssertEqual(halted?.choices, [.waitForReset, .finishOnPaidPath])
    }

    func testThePaidRouteSaysItCostsMoneyInItsOwnWords() {
        // Nothing is spent without Dan saying so, and a button cannot ask for
        // consent to a cost it does not mention.
        let label = HaltedWeek.Choice.finishOnPaidPath.label.lowercased()
        XCTAssertTrue(label.contains("paid") || label.contains("pay"),
                      "the paid route does not say it is paid: \(label)")
    }

    func testTheWaitingRouteDoesNotSpendAnything() {
        XCTAssertFalse(HaltedWeek.Choice.waitForReset.spendsMoney)
        XCTAssertTrue(HaltedWeek.Choice.finishOnPaidPath.spendsMoney)
    }

    func testTheTwoChoicesDoNotReadTheSame() {
        // Two buttons a person cannot tell apart are one button.
        XCTAssertNotEqual(HaltedWeek.Choice.waitForReset.label,
                          HaltedWeek.Choice.finishOnPaidPath.label)
    }

    // ── the wire ──────────────────────────────────────────────────────────────

    func testTheStopReasonSurvivesAJsonRoundTripFromPython() throws {
        // Python writes snake_case. A key mismatch here is silent: the field
        // decodes to nil and the halt goes back to being invisible.
        let json = """
        {"errors": {}, "warnings": {},
         "stopped_reason": "Claude usage limit reached, resets at 3pm."}
        """
        let decoded = try JSONDecoder().decode(
            WeekGenerationResult.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.stoppedReason, "Claude usage limit reached, resets at 3pm.")
    }

    func testAWeekSavedBeforeThisFieldExistedStillDecodes() {
        // Every persisted Codable field has to tolerate its own absence, or the
        // first launch after an upgrade wipes the saved week.
        let json = #"{"errors": {}, "warnings": {}}"#
        XCTAssertNoThrow(try JSONDecoder().decode(
            WeekGenerationResult.self, from: Data(json.utf8)))
    }
}

/// #257: the paid-path choice has to survive the transport setting.
final class PaidPathOverrideTests: XCTestCase {

    func testAnOrdinaryRunExportsNothing() {
        // An empty line, not `=1`. A run nobody asked to pay for must keep
        // whatever the setting says rather than being pinned either way.
        XCTAssertEqual(Transport.overrideExport(forcePaidPath: false), "")
    }

    func testChoosingToPayPinsThatRunToTheMeteredApi() {
        XCTAssertEqual(Transport.overrideExport(forcePaidPath: true),
                       "export POSTROLL_USE_SUBSCRIPTION=0")
    }

    func testTheOverrideTurnsTheSubscriptionOffRatherThanOn() {
        // Inverting this is the worst possible bug here: the button that says
        // it will pay would force the run onto the allowance that just ran out.
        let line = Transport.overrideExport(forcePaidPath: true)
        XCTAssertTrue(line.hasSuffix("=0"), "the paid override reads \(line)")
        XCTAssertFalse(line.hasSuffix("=1"))
    }

    func testItExportsTheNamePythonActuallyReads() {
        XCTAssertTrue(
            Transport.overrideExport(forcePaidPath: true)
                .contains(Transport.subscriptionEnv))
    }
}

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
