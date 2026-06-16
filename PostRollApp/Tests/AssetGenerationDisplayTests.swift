import XCTest

/// Pins the "switching events must not lose generation progress" fix. The
/// generation task lives app-scoped in GenerationManager, not in
/// AssetGenerationView's `@State`, so the screen state is *derived* from the
/// surviving run rather than reset when the view is remounted on an event
/// switch. These cases lock in that precedence rule.
final class AssetGenerationDisplayTests: XCTestCase {

    func testActiveRunShowsRunningEvenWithSavedResults() {
        // The regression: an event that already had results, now regenerating.
        // While a run is active it must read as running, not snap back to done.
        let display = AssetGenerationDisplay.resolve(
            runStatus: .running, forceConfigure: false, hasWeekResult: true)
        XCTAssertEqual(display, .running)
    }

    func testRunningWinsOverForceConfigure() {
        // Kicking off a fresh full run sets forceConfigure; the live run must
        // still take precedence so the user sees the progress screen.
        let display = AssetGenerationDisplay.resolve(
            runStatus: .running, forceConfigure: true, hasWeekResult: false)
        XCTAssertEqual(display, .running)
    }

    func testFailedRunSurfacesMessage() {
        let display = AssetGenerationDisplay.resolve(
            runStatus: .failed("boom"), forceConfigure: false, hasWeekResult: true)
        XCTAssertEqual(display, .failed("boom"))
    }

    func testNoRunWithResultsReadsAsDone() {
        // Run finished and was removed from the manager; the saved weekResult is
        // now the source of truth. This is what a returning user sees after a
        // background generation completed while they were on another event.
        let display = AssetGenerationDisplay.resolve(
            runStatus: nil, forceConfigure: false, hasWeekResult: true)
        XCTAssertEqual(display, .done)
    }

    func testNoRunNoResultsReadsAsConfiguring() {
        let display = AssetGenerationDisplay.resolve(
            runStatus: nil, forceConfigure: false, hasWeekResult: false)
        XCTAssertEqual(display, .configuring)
    }

    func testForceConfigureOverridesSavedResultsWhenIdle() {
        // "Regenerate all" forces the configuring screen even though results
        // exist, but only when no run is active (covered by the running tests).
        let display = AssetGenerationDisplay.resolve(
            runStatus: nil, forceConfigure: true, hasWeekResult: true)
        XCTAssertEqual(display, .configuring)
    }
}
