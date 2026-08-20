import XCTest

/// Pins the exact condition CaptionSection uses to decide whether Friday
/// shows the dual-slot reel+story review (#135) vs today's story-only
/// fallback. Both a real plan AND an on-disk reel file are required -
/// a stale plan pointing at a since-deleted/never-rendered reel must fall
/// back, not show a broken player.
final class FridayReviewDisplayTests: XCTestCase {

    private func plan(selections: [FridayClipSelection] = [FridayClipSelection(clipPath: "/a.mov", trimIn: 0, trimOut: 2, transition: .cut)]) -> FridayClipPlan {
        FridayClipPlan(selections: selections, rationale: "x")
    }

    func testShowsDualSlotWhenPlanHasSelectionsAndReelFileExists() {
        XCTAssertTrue(FridayReviewDisplay.showsDualSlot(
            fridayClipPlan: plan(), reelPath: "/reel.mp4", fileExists: { _ in true }
        ))
    }

    func testFallsBackWhenPlanIsNil() {
        XCTAssertFalse(FridayReviewDisplay.showsDualSlot(
            fridayClipPlan: nil, reelPath: "/reel.mp4", fileExists: { _ in true }
        ))
    }

    func testFallsBackWhenPlanHasNoSelections() {
        XCTAssertFalse(FridayReviewDisplay.showsDualSlot(
            fridayClipPlan: plan(selections: []), reelPath: "/reel.mp4", fileExists: { _ in true }
        ))
    }

    func testFallsBackWhenReelPathIsNil() {
        XCTAssertFalse(FridayReviewDisplay.showsDualSlot(
            fridayClipPlan: plan(), reelPath: nil, fileExists: { _ in true }
        ))
    }

    func testFallsBackWhenReelFileDoesNotExistOnDisk() {
        // A stale plan surviving after the rendered file was reclaimed/deleted
        // must not show a broken video player.
        XCTAssertFalse(FridayReviewDisplay.showsDualSlot(
            fridayClipPlan: plan(), reelPath: "/reel.mp4", fileExists: { _ in false }
        ))
    }

    // MARK: - The "< 3 usable clips" escape hatch (#135, #730)
    //
    // generate_media.py signals that case with a distinguishable
    // insufficient_clips: prefix, not a message meant for humans, so the card
    // can offer the two ways out rather than string-matching generic error
    // text.
    //
    // These record the failure the way the SCREEN records it, through
    // PreviewGraphicsManager, and then ask the question the card asks. The
    // previous versions handed the checker the bare marker, which the screen
    // never does: it goes through applyRegenResult, which recorded a sentence
    // with the marker buried inside it, so the check could not match and the
    // banner could not appear. Both tests passed the whole time (L3, L178).

    private let shortfall = "insufficient_clips: only 1 of 1 clips usable, need at least 3"

    @MainActor
    private func recorded(_ record: (PreviewGraphicsManager, UUID) -> Void)
    -> PreviewGraphicsManager.DayFailure? {
        let manager = PreviewGraphicsManager()
        let event = UUID()
        record(manager, event)
        return manager.dayFailure(.friday, for: event)
    }

    @MainActor
    func testTheEscapeHatchIsOfferedForAPipelineShortfall() {
        let failure = recorded { manager, event in
            manager.failDayRegen(.friday, for: event, pipelineError: shortfall)
        }
        XCTAssertTrue(FridayReviewDisplay.offersInsufficientClipsEscape(failure))
    }

    @MainActor
    func testTheSentenceDanReadsStillNamesTheShortfall() {
        // The decision moved off the sentence, so the sentence is free to
        // change; what it may not do is stop saying what happened. A failure
        // recorded with no reason at all would satisfy the check above.
        let failure = recorded { manager, event in
            manager.failDayRegen(.friday, for: event, pipelineError: shortfall)
        }
        XCTAssertEqual(failure?.reason,
                       "Friday regeneration failed: \(shortfall)")
    }

    @MainActor
    func testAWrappedSentenceIsNotAMarker() {
        // The defect itself. This is exactly what the screen used to record,
        // and it must not read as a pipeline shortfall: a failure whose marker
        // was folded into prose has lost it, and answering yes here would let
        // the wrapping back in while the card kept working (L103).
        let failure = recorded { manager, event in
            manager.failDayRegen(
                .friday, for: event,
                reason: "Friday regeneration failed: \(self.shortfall)")
        }
        XCTAssertFalse(FridayReviewDisplay.offersInsufficientClipsEscape(failure))
    }

    @MainActor
    func testOtherPipelineErrorsGetNoEscapeHatch() {
        // The other control: the buttons are the remedy for a shortfall alone.
        // A crashed encode is not fixed by importing more clips, and a rule
        // that offered them for everything would be advice that does not
        // change the state it is offered in (L111).
        for other in ["clip reel skipped: ffmpeg crashed",
                      "before/after failed: missing raw"] {
            let failure = recorded { manager, event in
                manager.failDayRegen(.friday, for: event, pipelineError: other)
            }
            XCTAssertFalse(FridayReviewDisplay.offersInsufficientClipsEscape(failure),
                           "\(other) is not a clip shortfall")
        }
    }

    func testNoFailureAtAllOffersNothing() {
        XCTAssertFalse(FridayReviewDisplay.offersInsufficientClipsEscape(nil))
    }
}
