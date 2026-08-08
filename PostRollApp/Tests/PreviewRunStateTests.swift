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
}
