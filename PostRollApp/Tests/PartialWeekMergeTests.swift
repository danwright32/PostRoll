import XCTest

/// #262: a halt must not delete the days it never reached.
///
/// The days after a halt are nil because nothing ran, not because they came
/// back blank. An ordinary full run replaces the saved week wholesale, and doing
/// that for a halt would throw away captions that had generated fine on an
/// earlier run, which Dan then pays to produce again.
final class PartialWeekMergeTests: XCTestCase {

    private func week(_ days: [DayName: String], blog: String? = nil,
                      stoppedReason: String? = nil) -> WeekGenerationResult {
        var w = WeekGenerationResult()
        for (day, caption) in days { w[day] = DayCaption(caption: caption) }
        if let blog { w.blog = BlogOutput(title: "t", body: blog) }
        w.stoppedReason = stoppedReason
        return w
    }

    // ── which branch a run takes (the ordering defect) ────────────────────────

    func testAHaltedPartialRetryStillProtectsTheDaysItNeverReached() {
        // The defect this ordering exists to prevent. A preset switch retries a
        // subset; the run caps after the first of them. Deciding by "is this a
        // partial retry" before "did this run stop" sent it down the ordinary
        // merge, which wrote nil over two days that were already generated.
        let saved = week([.sunday: "old sun", .monday: "old mon", .wednesday: "old wed"])
        let halted = week([.sunday: "new sun"], stoppedReason: "capped")

        let merged = PartialWeekMerge.merged(
            existing: saved, incoming: halted,
            onlyDays: ["sunday", "monday", "wednesday"], ending: .stoppedEarly)

        XCTAssertEqual(merged.sunday?.caption, "new sun")
        XCTAssertEqual(merged.monday?.caption, "old mon",
                       "Monday was in the retry's scope but the run stopped before "
                       + "reaching it, so its existing caption must survive")
        XCTAssertEqual(merged.wednesday?.caption, "old wed")
        XCTAssertFalse(merged.complete)
    }

    func testAFinishedPartialRetryDoesOverwriteItsOwnScope() {
        // The other half: a retry that DID finish is entitled to replace the
        // days it was asked for, including clearing one that came back empty.
        let saved = week([.sunday: "old sun", .monday: "old mon"])
        var incoming = week([.sunday: "new sun"])
        incoming.complete = true

        let merged = PartialWeekMerge.merged(
            existing: saved, incoming: incoming,
            onlyDays: ["sunday", "monday"], ending: .finished)

        XCTAssertEqual(merged.sunday?.caption, "new sun")
        XCTAssertNil(merged.monday, "the retry covered Monday and it produced nothing")
    }

    func testAFinishedRetryClearsAnEarlierHaltsBookkeeping() {
        // A recorded failure has to stop reading as current when its cause is
        // gone. Left behind, the done screen says "Stopped before finishing"
        // forever and the next unrelated error shows the paid-re-run screen
        // carrying last week's cap message.
        var saved = week([.sunday: "a"], stoppedReason: "Claude usage limit reached")
        saved.complete = false

        let merged = PartialWeekMerge.merged(
            existing: saved, incoming: week([.monday: "b"]),
            onlyDays: ["monday"], ending: .finished)

        XCTAssertNil(merged.stoppedReason)
        XCTAssertTrue(merged.complete)
        XCTAssertEqual(merged.sunday?.caption, "a")
        XCTAssertEqual(merged.monday?.caption, "b")
    }

    func testAFinishedFullRunReplacesTheWeekAndClearsTheHalt() {
        var saved = week([.sunday: "old", .friday: "old fri"], stoppedReason: "capped")
        saved.complete = false

        let merged = PartialWeekMerge.merged(
            existing: saved, incoming: week([.sunday: "new"]),
            onlyDays: nil, ending: .finished)

        XCTAssertEqual(merged.sunday?.caption, "new")
        XCTAssertNil(merged.friday, "a finished full run is the whole answer")
        XCTAssertNil(merged.stoppedReason)
        XCTAssertTrue(merged.complete)
    }

    func testAFinishedRetryWithNothingSavedYetIsTheWholeWeek() {
        let merged = PartialWeekMerge.merged(
            existing: nil, incoming: week([.sunday: "a"]),
            onlyDays: ["sunday"], ending: .finished)
        XCTAssertEqual(merged.sunday?.caption, "a")
        XCTAssertTrue(merged.complete)
    }

    // ── merging a run that stopped ────────────────────────────────────────────

    func testDaysTheHaltNeverReachedSurvive() {
        let saved = week([.sunday: "old sunday", .thursday: "old thursday"])
        let halted = week([.sunday: "new sunday"], stoppedReason: "capped")

        let merged = PartialWeekMerge.applying(halted, onto: saved)

        XCTAssertEqual(merged.sunday?.caption, "new sunday", "this run's work wins")
        XCTAssertEqual(merged.thursday?.caption, "old thursday",
                       "Thursday never ran, so it must still be there; wiping it "
                       + "throws away a caption that was already generated and paid for")
    }

    func testTheBlogSurvivesAHaltThatNeverReachedIt() {
        let saved = week([:], blog: "the whole post")
        let merged = PartialWeekMerge.applying(week([.sunday: "a"], stoppedReason: "capped"),
                                              onto: saved)
        XCTAssertEqual(merged.blog?.body, "the whole post")
    }

    func testANewBlogReplacesTheOldOne() {
        let saved = week([:], blog: "old post")
        let merged = PartialWeekMerge.applying(week([:], blog: "new post", stoppedReason: "capped"),
                                              onto: saved)
        XCTAssertEqual(merged.blog?.body, "new post")
    }

    func testTheHaltsOwnBookkeepingAlwaysWins() {
        // The previous save says the week finished. This run says it stopped.
        // The stale answer must not survive, or the halt screen never appears.
        var saved = week([.sunday: "a"])
        saved.complete = true
        saved.stoppedReason = nil

        let merged = PartialWeekMerge.applying(
            week([:], stoppedReason: "Claude usage limit reached"), onto: saved)

        XCTAssertFalse(merged.complete)
        XCTAssertEqual(merged.stoppedReason, "Claude usage limit reached")
    }

    func testUnrecognisedFailuresComeFromThisRunNotTheLastOne() {
        var saved = week([.sunday: "a"])
        saved.unrecognisedFailures = ["last week's oddity"]

        var halted = week([:], stoppedReason: "capped")
        halted.unrecognisedFailures = ["today's oddity"]

        let merged = PartialWeekMerge.applying(halted, onto: saved)
        XCTAssertEqual(merged.unrecognisedFailures, ["today's oddity"],
                       "a stale failure from an old run would send the cap "
                       + "calibration after the wrong text")
    }

    func testErrorsForDaysThisRunNeverReachedAreLeftAlone() {
        // Nothing was learned about them, so clearing them would report a
        // problem as resolved on no evidence.
        var saved = week([:])
        saved.errors = ["friday": "friday broke last time"]

        var halted = week([:], stoppedReason: "capped")
        halted.errors = ["sunday": "sunday broke now"]

        let merged = PartialWeekMerge.applying(halted, onto: saved)
        XCTAssertEqual(merged.errors["friday"], "friday broke last time")
        XCTAssertEqual(merged.errors["sunday"], "sunday broke now")
    }

    func testWithNothingSavedTheHaltedRunIsTheWeek() {
        let halted = week([.sunday: "a"], stoppedReason: "capped")
        let merged = PartialWeekMerge.applying(halted, onto: nil)
        XCTAssertEqual(merged.sunday?.caption, "a")
        XCTAssertEqual(merged.stoppedReason, "capped")
    }

    func testAHaltedFirstRunIsNotMarkedComplete() {
        let merged = PartialWeekMerge.applying(week([.sunday: "a"], stoppedReason: "capped"),
                                              onto: nil)
        XCTAssertFalse(merged.complete,
                       "Python already sent complete:false; a halted first run "
                       + "must not read as a finished week")
    }
}
