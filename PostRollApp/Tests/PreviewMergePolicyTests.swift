import XCTest

/// Cover for the generation run's preview-graphics decisions, extracted from
/// GenerationManager. The partial-retry merge in particular is the fix that lets
/// a preset switch rebuild only the affected days' previews without wiping the
/// rest.
final class PreviewMergePolicyTests: XCTestCase {

    // MARK: - shouldRenderGraphics

    func testFullRunRendersGraphicsByDefault() {
        XCTAssertTrue(PreviewMergePolicy.shouldRenderGraphics(regenerateGraphics: nil, isFullRun: true))
    }

    func testPartialRetrySkipsGraphicsByDefault() {
        XCTAssertFalse(PreviewMergePolicy.shouldRenderGraphics(regenerateGraphics: nil, isFullRun: false))
    }

    func testRegenerateGraphicsOverridesPartialRetry() {
        XCTAssertTrue(PreviewMergePolicy.shouldRenderGraphics(regenerateGraphics: true, isFullRun: false))
        XCTAssertFalse(PreviewMergePolicy.shouldRenderGraphics(regenerateGraphics: false, isFullRun: true))
    }

    // MARK: - merge

    func testFullRunReplacesEntireMap() {
        let existing = ["sunday": ["story": "/old/sun.png"], "tuesday": ["reel": "/old/tue.mp4"]]
        let fresh = ["sunday": ["collage": "/new/sun.png"]]
        let merged = PreviewMergePolicy.merge(existing: existing, fresh: fresh, isFullRun: true)
        XCTAssertEqual(merged, fresh, "a full run replaces all previews")
    }

    func testPartialRetryMergesOnlyRegeneratedDays() {
        let existing = ["sunday": ["story": "/old/sun.png"], "tuesday": ["reel": "/old/tue.mp4"]]
        let fresh = ["sunday": ["collage": "/new/sun.png"]]
        let merged = PreviewMergePolicy.merge(existing: existing, fresh: fresh, isFullRun: false)
        XCTAssertEqual(merged["sunday"], ["collage": "/new/sun.png"], "regenerated day is updated")
        XCTAssertEqual(merged["tuesday"], ["reel": "/old/tue.mp4"], "untouched day's preview survives")
    }

    func testEmptyOrNilFreshLeavesExistingUntouched() {
        let existing = ["sunday": ["story": "/old/sun.png"]]
        XCTAssertEqual(PreviewMergePolicy.merge(existing: existing, fresh: nil, isFullRun: false), existing)
        XCTAssertEqual(PreviewMergePolicy.merge(existing: existing, fresh: [:], isFullRun: true), existing)
    }
}
