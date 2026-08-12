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

    func testTheReviewBannerSaysWhatSurvivedAndWhereToGo() {
        // #262: the caption review screen has no room for the two buttons, and
        // rendering the halt as a bare red error there reads as a crash, whose
        // obvious answer is to run the whole week again, which is the one thing
        // that costs money it need not.
        let halted = HaltedWeek.from(result(
            stoppedReason: "Claude usage limit reached",
            days: [.sunday, .monday]))
        let banner = halted?.reviewBanner ?? ""
        XCTAssertTrue(banner.contains("Claude usage limit reached"), banner)
        XCTAssertTrue(banner.contains("Sunday"), banner)
        XCTAssertTrue(banner.contains("saved"), banner)
        XCTAssertTrue(banner.lowercased().contains("generate screen"), banner)
    }

    func testTheReviewBannerDoesNotClaimWorkSurvivedWhenNoneDid() {
        let halted = HaltedWeek.from(result(stoppedReason: "capped", days: []))
        XCTAssertTrue(halted?.reviewBanner.contains("Nothing had finished") ?? false,
                      halted?.reviewBanner ?? "nil")
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
