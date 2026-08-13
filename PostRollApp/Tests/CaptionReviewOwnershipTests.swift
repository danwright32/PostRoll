import XCTest

/// #456: five long-running jobs lived in `CaptionReviewView`'s `@State`, and
/// the `.id(event.id)` remount that #75 proved is a real path discarded every
/// one of them mid-flight.
///
/// These drive the state model and the manager directly, because a remount is
/// exactly "the view's storage goes away and the manager's does not": a test
/// that owned the state itself would be asserting its own copy.
final class CaptionReviewOwnershipTests: XCTestCase {

    private let eventA = UUID()
    private let eventB = UUID()

    // MARK: - Per-day elapsed time survives (regenerationStartTimes)

    func testADayRegenRecordsWhenItStarted() {
        var state = PreviewRunState()
        let began = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(state.beginDay(.thursday, for: eventA, at: began))

        // Without this the spinner has no elapsed time to show, which is the
        // indistinct state #135 exists to prevent.
        XCTAssertEqual(state.dayStartedAt(.thursday, for: eventA), began)
    }

    func testASecondStartForTheSameDayIsRefusedAndKeepsTheOriginalTime() {
        var state = PreviewRunState()
        let began = Date(timeIntervalSince1970: 1_000)
        _ = state.beginDay(.thursday, for: eventA, at: began)

        XCTAssertFalse(state.beginDay(.thursday, for: eventA,
                                      at: began.addingTimeInterval(30)))
        XCTAssertEqual(state.dayStartedAt(.thursday, for: eventA), began,
                       "a refused duplicate moved the clock, so the run looks younger than it is")
    }

    func testEndingADayClearsItsTime() {
        var state = PreviewRunState()
        _ = state.beginDay(.thursday, for: eventA)
        state.endDay(.thursday, for: eventA)
        XCTAssertNil(state.dayStartedAt(.thursday, for: eventA))
    }

    func testOneEventsDayRunIsNotAnothers() {
        var state = PreviewRunState()
        _ = state.beginDay(.thursday, for: eventA)
        XCTAssertNil(state.dayStartedAt(.thursday, for: eventB))
        XCTAssertTrue(state.regeneratingDays(for: eventB).isEmpty)
    }

    // MARK: - Cover regeneration stays separate from day regeneration (#141)

    func testACoverRegenIsNotADayRegen() {
        var state = PreviewRunState()
        state.beginCover(.thursday, for: eventA)

        XCTAssertTrue(state.coverRegeneratingDays(for: eventA).contains(.thursday))
        // The whole reason these are separate fields: regenerating a cover must
        // never look like, or trigger, a full reel or story regen.
        XCTAssertTrue(state.regeneratingDays(for: eventA).isEmpty)
        XCTAssertFalse(state.isBusy(eventA))
    }

    func testASecondCoverRegenForTheSameDayIsRefused() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginCover(.friday, for: eventA))
        XCTAssertFalse(state.beginCover(.friday, for: eventA),
                       "a second cover regen writes the same file as the first")
    }

    func testEndingACoverRegenClearsBothTheDayAndItsTime() {
        var state = PreviewRunState()
        state.beginCover(.friday, for: eventA)
        state.endCover(.friday, for: eventA)
        XCTAssertTrue(state.coverRegeneratingDays(for: eventA).isEmpty)
        XCTAssertNil(state.coverStartedAt(.friday, for: eventA))
    }

    // MARK: - The jobs outlive the screen

    @MainActor
    func testTheSpeculativeRendererIsTheSameOneAcrossARemount() {
        let manager = PreviewGraphicsManager.shared

        let first = manager.speculativeReel(for: eventA)
        // A remount asks again. Getting a FRESH renderer is the defect: its
        // anti-collision guard would know nothing about the encode the orphan
        // is still running, and both write the same reel.mp4.
        let afterRemount = manager.speculativeReel(for: eventA)

        XCTAssertTrue(first === afterRemount)
    }

    @MainActor
    func testEachEventGetsItsOwnRenderer() {
        let manager = PreviewGraphicsManager.shared
        XCTAssertFalse(manager.speculativeReel(for: eventA) === manager.speculativeReel(for: eventB))
    }

    @MainActor
    func testASecondThursdayEditorBuildIsRefusedWhileOneIsRunning() {
        let manager = PreviewGraphicsManager.shared
        defer { manager.finishThursdayEditorBuild(eventA, url: nil) }

        XCTAssertTrue(manager.beginThursdayEditorBuild(eventA))
        // The remount case: the screen comes back, sees no built URL, and asks
        // again while the first build is still going.
        XCTAssertFalse(manager.beginThursdayEditorBuild(eventA),
                       "two builds write the same PNG and layout JSON")
    }

    @MainActor
    func testAFinishedThursdayEditorSurvivesTheRemountThatAskedForIt() {
        let manager = PreviewGraphicsManager.shared
        let built = URL(fileURLWithPath: "/tmp/reel_preview.png")
        defer { manager.invalidateThursdayEditor(eventA) }

        _ = manager.beginThursdayEditorBuild(eventA)
        manager.finishThursdayEditorBuild(eventA, url: built)

        XCTAssertEqual(manager.thursdayEditorURL(eventA), built)
        XCTAssertFalse(manager.isBuildingThursdayEditor(eventA))
    }

    @MainActor
    func testAFailedThursdayEditorBuildDoesNotLeaveTheGuardStuck() {
        let manager = PreviewGraphicsManager.shared
        _ = manager.beginThursdayEditorBuild(eventB)
        // The build threw, so there is no URL. The guard still has to release,
        // or nothing can ever build the editor for this event again.
        manager.finishThursdayEditorBuild(eventB, url: nil)

        XCTAssertFalse(manager.isBuildingThursdayEditor(eventB))
        XCTAssertNil(manager.thursdayEditorURL(eventB))
        XCTAssertTrue(manager.beginThursdayEditorBuild(eventB))
        manager.finishThursdayEditorBuild(eventB, url: nil)
    }

    // MARK: - The generation run no longer bypasses the guard

    @MainActor
    func testAFullRunClaimedElsewhereBlocksASecondOne() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer { manager.endFullRun(id) }

        XCTAssertTrue(manager.beginFullRun(id))
        // GenerationManager's graphics pass went straight to the bridge, so the
        // guard could not see it and a review-screen run could start beside it.
        XCTAssertFalse(manager.beginFullRun(id))
        XCTAssertTrue(manager.isGenerating(id))
    }

    // MARK: - A failed build is not a slow one

    @MainActor
    func testAFailedThursdayEditorBuildIsReportedRatherThanLeftSpinning() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()

        _ = manager.beginThursdayEditorBuild(id)
        manager.failThursdayEditorBuild(id, reason: "ffmpeg is not installed.")

        // Without this the card sits on "Loading…" for as long as it is open,
        // which is a spinner over a failure (L10).
        XCTAssertEqual(manager.thursdayEditorFailure(id), "ffmpeg is not installed.")
        XCTAssertFalse(manager.isBuildingThursdayEditor(id))
        XCTAssertNil(manager.thursdayEditorURL(id))
    }

    @MainActor
    func testRetryingClearsTheFailureSoTheCardStopsShowingIt() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        manager.failThursdayEditorBuild(id, reason: "ffmpeg is not installed.")

        XCTAssertTrue(manager.beginThursdayEditorBuild(id))

        // A stored error that outlives the run it was about reads as a failure
        // that is happening now.
        XCTAssertNil(manager.thursdayEditorFailure(id))
        manager.finishThursdayEditorBuild(id, url: nil)
    }
}
