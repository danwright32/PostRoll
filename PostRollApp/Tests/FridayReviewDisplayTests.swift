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
}
