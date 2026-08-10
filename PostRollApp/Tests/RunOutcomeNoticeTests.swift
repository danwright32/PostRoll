import XCTest

/// #262: what the finished screen may claim about a run.
final class RunOutcomeNoticeTests: XCTestCase {

    private func week(complete: Bool = true, unrecognised: [String] = []) -> WeekGenerationResult {
        var w = WeekGenerationResult()
        w.complete = complete
        w.unrecognisedFailures = unrecognised
        return w
    }

    // ── complete ──────────────────────────────────────────────────────────────

    func testACleanRunSaysContentGenerated() {
        XCTAssertEqual(RunOutcomeNotice.headline(week: week(), failedDayCount: 0),
                       "Content generated")
        XCTAssertTrue(RunOutcomeNotice.isUnqualifiedSuccess(week: week(), failedDayCount: 0))
    }

    func testARunWithFailedDaysSaysPartially() {
        XCTAssertEqual(RunOutcomeNotice.headline(week: week(), failedDayCount: 2),
                       "Partially generated")
        XCTAssertFalse(RunOutcomeNotice.isUnqualifiedSuccess(week: week(), failedDayCount: 2))
    }

    func testARunThatNeverFinishedIsNotCalledGenerated() {
        // The 1800s watchdog kills the subprocess without an exception, so the
        // only trace is complete:false. Before this was read, a week cut off
        // mid-run showed the same checkmark and the same sentence as one that
        // finished, with days silently absent.
        let cut = week(complete: false)
        XCTAssertEqual(RunOutcomeNotice.headline(week: cut, failedDayCount: 0),
                       "Stopped before finishing")
        XCTAssertFalse(RunOutcomeNotice.isUnqualifiedSuccess(week: cut, failedDayCount: 0),
                       "an unfinished run must not get the reassuring filled mark")
    }

    func testNotFinishingOutranksPerDayFailures() {
        // "Partially generated" implies the run got to the end and some days
        // failed. It did not get to the end.
        XCTAssertEqual(RunOutcomeNotice.headline(week: week(complete: false), failedDayCount: 3),
                       "Stopped before finishing")
    }

    func testAWeekFromBeforeThisFieldExistedReadsAsFinished() {
        // Defaulting the other way would relabel every previously generated week
        // as cut off.
        XCTAssertEqual(RunOutcomeNotice.headline(week: WeekGenerationResult(), failedDayCount: 0),
                       "Content generated")
    }

    func testNoWeekAtAllIsNotCalledUnfinished() {
        XCTAssertEqual(RunOutcomeNotice.headline(week: nil, failedDayCount: 0),
                       "Content generated")
    }

    // ── unrecognised failures ─────────────────────────────────────────────────

    func testAnOrdinaryRunShowsNoUnfamiliarFailureNote() {
        XCTAssertNil(RunOutcomeNotice.unfamiliarFailureNote(week: week()),
                     "a note on every run is a note nobody reads by the time it matters")
        XCTAssertNil(RunOutcomeNotice.unfamiliarFailureNote(week: nil))
    }

    func testOneUnfamiliarFailureIsReportedInTheSingular() throws {
        let note = try XCTUnwrap(
            RunOutcomeNotice.unfamiliarFailureNote(week: week(unrecognised: ["upstream error"])))
        XCTAssertTrue(note.contains("one failure"), note)
    }

    func testSeveralUnfamiliarFailuresAreCounted() throws {
        let note = try XCTUnwrap(RunOutcomeNotice.unfamiliarFailureNote(
            week: week(unrecognised: ["a", "b", "c"])))
        XCTAssertTrue(note.contains("3 failures"), note)
    }

    func testTheNoteDoesNotClaimTheRunFailed() {
        // An unrecognised failure does NOT halt the week: an unfamiliar error is
        // far more likely to be a blip, and stopping on it costs an evening.
        // Saying the run failed would be claiming more than was measured.
        let note = RunOutcomeNotice.unfamiliarFailureNote(week: week(unrecognised: ["x"])) ?? ""
        XCTAssertFalse(note.lowercased().contains("the run failed"), note)
    }
}
