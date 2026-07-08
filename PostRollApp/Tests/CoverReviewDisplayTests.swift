import XCTest

/// Pins the exact conditions CaptionSection uses to decide whether the
/// Cover card renders (#141): a stale cover path pointing at a since-
/// deleted/reclaimed file must fall back, not show a broken image (same
/// discipline as FridayReviewDisplay.showsDualSlot). Also pins which
/// rationale text shows: the AI's, or none once a manual override is in
/// effect (there's no AI rationale for the user's own pick).
final class CoverReviewDisplayTests: XCTestCase {

    // MARK: - showsCover

    func testShowsCoverWhenPathExistsOnDisk() {
        XCTAssertTrue(CoverReviewDisplay.showsCover(coverPath: "/cover.png", fileExists: { _ in true }))
    }

    func testFallsBackWhenPathIsNil() {
        XCTAssertFalse(CoverReviewDisplay.showsCover(coverPath: nil, fileExists: { _ in true }))
    }

    func testFallsBackWhenFileDoesNotExistOnDisk() {
        XCTAssertFalse(CoverReviewDisplay.showsCover(coverPath: "/cover.png", fileExists: { _ in false }))
    }

    // MARK: - rationale

    func testShowsAIRationaleWhenNoOverride() {
        let pick = CoverPick(sourcePath: "/x.jpg", rationale: "sharp soloist")
        XCTAssertEqual(CoverReviewDisplay.rationale(coverOverride: nil, coverPick: pick), "sharp soloist")
    }

    func testNoRationaleWhenOverrideIsSet() {
        let pick = CoverPick(sourcePath: "/x.jpg", rationale: "sharp soloist")
        XCTAssertNil(CoverReviewDisplay.rationale(coverOverride: "/user_choice.jpg", coverPick: pick),
                     "a manual override has no AI rationale to show, even if a stale pick is still persisted")
    }

    func testNoRationaleWhenNoPickExists() {
        XCTAssertNil(CoverReviewDisplay.rationale(coverOverride: nil, coverPick: nil))
    }

    func testNoRationaleWhenPickRationaleIsEmpty() {
        let pick = CoverPick(sourcePath: "/x.jpg", rationale: "")
        XCTAssertNil(CoverReviewDisplay.rationale(coverOverride: nil, coverPick: pick))
    }
}
