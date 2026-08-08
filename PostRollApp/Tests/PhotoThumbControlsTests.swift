import XCTest

/// Regression guard for a defect found on 2026-08-07: per-photo tagging was
/// reachable only on days that also had crop enabled. `enableCrop` is
/// Wednesday and Thursday only, while carousel tagging covers Sunday and
/// Monday too under the balanced preset, so the tag button (and later the
/// batch selection circle) silently never rendered on Sunday or Monday even
/// though the tag data was wired all the way through to CAPTIONS.txt.
///
/// Cropping and tagging are separate features that happen to share a
/// thumbnail. Neither may gate the other.
final class PhotoThumbControlsTests: XCTestCase {

    func testTaggingShowsOnADayThatHasNoCrop() {
        XCTAssertTrue(
            PhotoThumbControls.showsTagging(taggingEnabled: true, cropEnabled: false),
            "a carousel day without crop must still offer per-photo tagging")
    }

    func testCropShowsOnADayThatHasNoTagging() {
        XCTAssertTrue(
            PhotoThumbControls.showsCrop(cropEnabled: true, taggingEnabled: false),
            "a cropping day that isn't a carousel must still offer crop")
    }

    func testTheDetailedThumbIsUsedWheneverEitherFeatureIsOn() {
        XCTAssertTrue(PhotoThumbControls.usesDetailedThumb(cropEnabled: true, taggingEnabled: false))
        XCTAssertTrue(PhotoThumbControls.usesDetailedThumb(cropEnabled: false, taggingEnabled: true),
                      "tagging alone must be enough to render the thumbnail that carries the controls")
        XCTAssertTrue(PhotoThumbControls.usesDetailedThumb(cropEnabled: true, taggingEnabled: true))
    }

    func testThePlainThumbIsUsedWhenNeitherFeatureIsOn() {
        XCTAssertFalse(PhotoThumbControls.usesDetailedThumb(cropEnabled: false, taggingEnabled: false))
    }

    func testEachControlStaysOffWhenItsOwnFeatureIsOff() {
        XCTAssertFalse(PhotoThumbControls.showsTagging(taggingEnabled: false, cropEnabled: true),
                       "a cropping day that isn't a carousel must not offer tagging")
        XCTAssertFalse(PhotoThumbControls.showsCrop(cropEnabled: false, taggingEnabled: true),
                       "a carousel day without crop must not offer crop")
    }
}
