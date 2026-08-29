import XCTest

/// Preview-graphics runs used to live in CaptionReviewView's @State, which the
/// `.id(event.id)` remount on every event switch throws away while the
/// unstructured Task keeps going. Coming back auto-started a second run against
/// the same output files, and the first one became invisible (#75).
///
/// Ownership moved to an app-scoped manager over this state, so the rule that
/// makes that safe is pinned here: a second start for an event already running
/// is refused, and what's in flight outlives any view.
final class PreviewRunStateTests: XCTestCase {

    private let eventA = UUID()
    private let eventB = UUID()

    // MARK: - A full run and a day run are the same writer (#1009)

    /// The two claims never consulted each other, so both said yes for one
    /// event and two `generate_media` subprocesses ran against the same files.
    ///
    /// They also collide on one file: `PythonBridge.runPreviewGeneration`
    /// deletes `AppPaths.mediaProgressFile(forEventID:)`, which is per EVENT,
    /// and `AppPaths` carries a comment recording why sharing that file is
    /// wrong (one overwrites the other's label, so the screen flips and neither
    /// surface can trust what it reads). Making the claims exclusive is what
    /// removes the collision, rather than a second fix on the file.
    func testADayRegenIsRefusedWhileAFullRunIsInFlight() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginFullRun(eventA))

        XCTAssertFalse(state.beginDay(.wednesday, for: eventA),
                       "a full run already writes every day's media, so a day run "
                       + "beside it is a second writer on the same files")
        XCTAssertTrue(state.regeneratingDays(for: eventA).isEmpty,
                      "a refused claim must not record the day as running, or the "
                      + "spinner outlives a run nobody started")
    }

    func testAFullRunIsRefusedWhileAnyDayIsRegenerating() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginDay(.wednesday, for: eventA))

        XCTAssertFalse(state.beginFullRun(eventA),
                       "a full run writes the day already being written")
        XCTAssertFalse(state.isRunningFull(eventA),
                       "a refused full run must not record itself as running")
    }

    /// The exclusion is per event, like every other rule here.
    func testAFullRunOnOneEventDoesNotBlockADayOnAnother() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginFullRun(eventA))

        XCTAssertTrue(state.beginDay(.wednesday, for: eventB),
                      "two events write different folders and different progress files")
    }

    /// Cover runs stay OUTSIDE this rule, deliberately (#141).
    ///
    /// A cover regeneration must never look like, or trigger, a full reel or
    /// story regen, which is why `isBusy` has never counted them. Folding them
    /// into the exclusion here would make a cover refresh block a rebuild and
    /// vice versa, which is a behaviour change nobody asked for and the opposite
    /// of what #141 established.
    func testACoverRegenIsNotBlockedByAFullRunAndDoesNotBlockOne() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginFullRun(eventA))
        XCTAssertTrue(state.beginCover(.thursday, for: eventA),
                      "a cover refresh is not a media run and never was")

        var other = PreviewRunState()
        XCTAssertTrue(other.beginCover(.thursday, for: eventA))
        XCTAssertTrue(other.beginFullRun(eventA),
                      "an in flight cover refresh must not block a rebuild")
    }

    /// Ending the blocker releases the block, in both directions.
    func testEachClaimBecomesAvailableAgainWhenTheOtherEnds() {
        var state = PreviewRunState()
        _ = state.beginFullRun(eventA)
        state.endFullRun(eventA)
        XCTAssertTrue(state.beginDay(.wednesday, for: eventA),
                      "the full run is over, so a day run is free to start")

        state.endDay(.wednesday, for: eventA)
        XCTAssertTrue(state.beginFullRun(eventA),
                      "the last day run ended, so a full run is free to start")
    }

    func testASecondFullRunForTheSameEventIsRefused() {
        var state = PreviewRunState()

        XCTAssertTrue(state.beginFullRun(eventA), "first start is allowed")
        XCTAssertFalse(state.beginFullRun(eventA), "a remount must not start a second writer")
        XCTAssertTrue(state.isRunningFull(eventA))
    }

    func testAnotherEventCanRunAtTheSameTime() {
        var state = PreviewRunState()
        _ = state.beginFullRun(eventA)

        XCTAssertTrue(state.beginFullRun(eventB), "events are independent")
    }

    func testEndingARunLetsTheNextOneStart() {
        var state = PreviewRunState()
        _ = state.beginFullRun(eventA)

        state.endFullRun(eventA)

        XCTAssertFalse(state.isRunningFull(eventA))
        XCTAssertTrue(state.beginFullRun(eventA))
    }

    func testASecondRegenOfTheSameDayIsRefusedButOtherDaysAreNot() {
        var state = PreviewRunState()

        XCTAssertTrue(state.beginDay(.wednesday, for: eventA))
        XCTAssertFalse(state.beginDay(.wednesday, for: eventA))
        XCTAssertTrue(state.beginDay(.thursday, for: eventA))
        XCTAssertEqual(state.regeneratingDays(for: eventA), [.wednesday, .thursday])
    }

    func testEndingADayLeavesTheOthersRunning() {
        var state = PreviewRunState()
        _ = state.beginDay(.wednesday, for: eventA)
        _ = state.beginDay(.thursday, for: eventA)

        state.endDay(.wednesday, for: eventA)

        XCTAssertEqual(state.regeneratingDays(for: eventA), [.thursday])
    }

    func testDaysInFlightAreReportedPerEventNotGlobally() {
        var state = PreviewRunState()
        _ = state.beginDay(.wednesday, for: eventA)

        XCTAssertTrue(state.regeneratingDays(for: eventB).isEmpty)
    }

    func testBusyCoversBothKindsOfRun() {
        var state = PreviewRunState()
        XCTAssertFalse(state.isBusy(eventA))

        _ = state.beginDay(.friday, for: eventA)
        XCTAssertTrue(state.isBusy(eventA), "a per-day regen counts as busy")

        state.endDay(.friday, for: eventA)
        _ = state.beginFullRun(eventA)
        XCTAssertTrue(state.isBusy(eventA))
    }

    // MARK: - The image refresh counter belongs here (#1009)

    /// The counter that makes a rebuilt image actually appear on screen lived
    /// as view state on the caption review screen, written in six places there
    /// and read in one.
    ///
    /// So a redraw driven from any OTHER screen completed successfully and left
    /// the review screen showing the previous collage, with nothing saying so.
    /// A silent stale image after a successful rebuild is worse than a failed
    /// one: the failure at least says something.
    ///
    /// Keyed by EVENT as well as day. As view state it was keyed by day alone
    /// and survived only until the screen remounted, so it could not answer the
    /// question at all once more than one screen could ask it.
    func testAFinishedRedrawBumpsTheVersionForThatDayAndEvent() {
        var state = PreviewRunState()

        XCTAssertEqual(state.graphicVersion(.wednesday, for: eventA), 0,
                       "a day nothing has rebuilt starts at zero")

        state.bumpGraphicVersion(.wednesday, for: eventA)

        XCTAssertEqual(state.graphicVersion(.wednesday, for: eventA), 1)
        XCTAssertEqual(state.graphicVersion(.sunday, for: eventA), 0,
                       "only the day that was redrawn refreshes")
        XCTAssertEqual(state.graphicVersion(.wednesday, for: eventB), 0,
                       "another event's Wednesday is a different image")
    }

    /// Two rebuilds of one day are two refreshes, not one.
    ///
    /// The reader compares the number it last drew against the number now, so a
    /// counter that saturated would leave the second rebuild invisible.
    func testASecondRedrawOfTheSameDayBumpsAgain() {
        var state = PreviewRunState()
        state.bumpGraphicVersion(.thursday, for: eventA)
        state.bumpGraphicVersion(.thursday, for: eventA)

        XCTAssertEqual(state.graphicVersion(.thursday, for: eventA), 2)
    }
}
