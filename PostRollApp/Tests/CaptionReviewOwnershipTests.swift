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

    // MARK: - Two days claimed together, or not at all (#728)

    @MainActor
    func testClaimingTwoFreeDaysClaimsBoth() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer { [DayName.tuesday, .friday].forEach { manager.endDayRegen($0, for: id) } }

        XCTAssertTrue(manager.beginDayRegen([.tuesday, .friday], for: id))

        XCTAssertEqual(manager.regeneratingDays(id), [.tuesday, .friday])
    }

    @MainActor
    func testClaimingTwoDaysWhenOneIsBusyClaimsNeither() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer { manager.endDayRegen(.friday, for: id) }
        _ = manager.beginDayRegen(.friday, for: id)

        XCTAssertFalse(manager.beginDayRegen([.tuesday, .friday], for: id))

        // Half a claim is the state this exists to prevent: the action's write
        // covers both days, so Tuesday rebuilding alone would leave Friday
        // carrying new photos with the old graphic rendered.
        XCTAssertFalse(manager.regeneratingDays(id).contains(.tuesday),
                       "Tuesday was claimed and left claimed by a refused pair, "
                       + "so nothing can ever rebuild it again")
    }

    @MainActor
    func testARefusedPairLeavesTheFreeDaysStoredReasonAlone() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer {
            manager.endDayRegen(.friday, for: id)
            manager.clearDayFailure(.tuesday, for: id)
        }
        manager.failDayRegen(.tuesday, for: id, reason: "Tuesday regeneration failed.")
        _ = manager.beginDayRegen(.friday, for: id)

        XCTAssertFalse(manager.beginDayRegen([.tuesday, .friday], for: id))

        // Claiming clears a day's reason, so a pair that claims and rolls back
        // would take away a failure Dan has not read while starting nothing
        // (#721, L148).
        XCTAssertEqual(manager.dayFailure(.tuesday, for: id), "Tuesday regeneration failed.")
    }

    @MainActor
    func testClaimingAnEmptyListStartsNothing() {
        // Nothing to rebuild is not a rebuild. Answering true would have the
        // caller persist its write and wait for a run nobody started.
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        XCTAssertFalse(manager.beginDayRegen([], for: id))
        XCTAssertTrue(manager.regeneratingDays(id).isEmpty)
    }

    // MARK: - A short action's failure outlives the screen too (#721)
    //
    // Every one of these ran through `regenerateError`, one string on the view,
    // written from the audio swap, the cover rebuild, the Friday reel edit and
    // the per-day rebuild alike. Whichever failed last erased the reason before
    // it (L53), and the runs owned here already outlive the screen, so an audio
    // swap that failed while Dan was on another event left nothing at all
    // (L148).

    @MainActor
    func testAFailedDayRebuildKeepsItsReasonAndReleasesTheSlot() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        _ = manager.beginDayRegen(.tuesday, for: id)

        manager.failDayRegen(.tuesday, for: id, reason: "Tuesday audio swap failed: no track.")

        XCTAssertEqual(manager.dayFailure(.tuesday, for: id),
                       "Tuesday audio swap failed: no track.")
        XCTAssertFalse(manager.regeneratingDays(id).contains(.tuesday),
                       "the slot is still held, so nothing can rebuild that day again")
    }

    @MainActor
    func testTwoDaysFailuresDoNotEraseEachOther() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer { DayName.allCases.forEach { manager.clearDayFailure($0, for: id) } }

        manager.failDayRegen(.tuesday, for: id, reason: "Tuesday audio swap failed.")
        manager.failDayRegen(.thursday, for: id, reason: "Thursday regeneration failed.")

        XCTAssertEqual(manager.dayFailure(.tuesday, for: id), "Tuesday audio swap failed.",
                       "the second failure erased the first, which is the whole defect")
        XCTAssertEqual(manager.dayFailure(.thursday, for: id), "Thursday regeneration failed.")
    }

    @MainActor
    func testACoverFailureAndADayFailureOnOneDayAreKeptApart() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer {
            manager.clearDayFailure(.friday, for: id)
            manager.clearCoverFailure(.friday, for: id)
        }

        manager.failDayRegen(.friday, for: id, reason: "Friday reel edit failed.")
        manager.failCoverRegen(.friday, for: id, reason: "Friday cover regeneration failed.")

        // Two different runs on one day, with two different remedies. Reporting
        // the cover's failure as the reel's would send Dan to rebuild the wrong
        // thing (L11).
        XCTAssertEqual(manager.dayFailure(.friday, for: id), "Friday reel edit failed.")
        XCTAssertEqual(manager.coverFailure(.friday, for: id),
                       "Friday cover regeneration failed.")
    }

    @MainActor
    func testRetryingADayClearsItsOwnFailureAndNobodyElses() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer {
            manager.endDayRegen(.tuesday, for: id)
            manager.clearDayFailure(.thursday, for: id)
            manager.clearCoverFailure(.tuesday, for: id)
        }
        manager.failDayRegen(.tuesday, for: id, reason: "Tuesday regeneration failed.")
        manager.failDayRegen(.thursday, for: id, reason: "Thursday regeneration failed.")
        manager.failCoverRegen(.tuesday, for: id, reason: "Tuesday cover failed.")

        XCTAssertTrue(manager.beginDayRegen(.tuesday, for: id))

        // A stored error that outlives the run it was about reads as a failure
        // happening now.
        XCTAssertNil(manager.dayFailure(.tuesday, for: id))
        XCTAssertEqual(manager.dayFailure(.thursday, for: id), "Thursday regeneration failed.",
                       "retrying one day wiped another day's reason")
        XCTAssertEqual(manager.coverFailure(.tuesday, for: id), "Tuesday cover failed.",
                       "rebuilding the reel cleared the cover's reason, which is "
                       + "still true and still needs acting on")
    }

    @MainActor
    func testRetryingACoverClearsOnlyTheCoversFailure() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer {
            manager.endCoverRegen(.friday, for: id)
            manager.clearDayFailure(.friday, for: id)
        }
        manager.failDayRegen(.friday, for: id, reason: "Friday reel edit failed.")
        manager.failCoverRegen(.friday, for: id, reason: "Friday cover failed.")

        XCTAssertTrue(manager.beginCoverRegen(.friday, for: id))

        XCTAssertNil(manager.coverFailure(.friday, for: id))
        XCTAssertEqual(manager.dayFailure(.friday, for: id), "Friday reel edit failed.")
    }

    @MainActor
    func testOneEventsFailureIsNotAnothers() {
        let manager = PreviewGraphicsManager.shared
        let a = UUID(), b = UUID()
        defer { manager.clearDayFailure(.tuesday, for: a) }

        manager.failDayRegen(.tuesday, for: a, reason: "Tuesday audio swap failed.")

        XCTAssertNil(manager.dayFailure(.tuesday, for: b))
        XCTAssertTrue(manager.dayFailures(for: b).isEmpty)
    }

    @MainActor
    func testTheFailuresAreListedInTheWeeksOwnOrder() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer { DayName.allCases.forEach { manager.clearDayFailure($0, for: id) } }

        // Recorded out of order on purpose: a dictionary's order is not stable,
        // and a list that reshuffles between redraws cannot be told from one
        // that changed.
        manager.failDayRegen(.thursday, for: id, reason: "Thursday failed.")
        manager.failDayRegen(.tuesday, for: id, reason: "Tuesday failed.")

        XCTAssertEqual(manager.dayFailures(for: id),
                       [.init(day: .tuesday, reason: "Tuesday failed."),
                        .init(day: .thursday, reason: "Thursday failed.")])
    }

    @MainActor
    func testDismissingOneFailureLeavesTheRest() {
        let manager = PreviewGraphicsManager.shared
        let id = UUID()
        defer { manager.clearDayFailure(.thursday, for: id) }
        manager.failDayRegen(.tuesday, for: id, reason: "Tuesday failed.")
        manager.failDayRegen(.thursday, for: id, reason: "Thursday failed.")

        manager.clearDayFailure(.tuesday, for: id)

        XCTAssertNil(manager.dayFailure(.tuesday, for: id))
        XCTAssertEqual(manager.dayFailures(for: id),
                       [.init(day: .thursday, reason: "Thursday failed.")])
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
