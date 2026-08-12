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

/// The rule from #189, and the source held to it.
///
/// A rule nobody consults is decoration, so the expectation below is READ from
/// `offersCropControl` rather than hardcoded: changing the rule changes what
/// the source is required to contain, which is the point of naming it.
extension UploadPageCropRemovalTests {

    private var uploadView: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/PhotoAssignmentView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testTheSourceIsReadable() {
        XCTAssertTrue(uploadView.contains("NSOpenPanel"),
                      "the scan found the wrong file, so the check below proves nothing")
    }

    func testTheUploadPageOffersNoCropControl() {
        XCTAssertFalse(PhotoThumbControls.offersCropControl(on: .upload))
    }

    func testTheReviewPageIsStillWhereCroppingHappens() {
        XCTAssertTrue(PhotoThumbControls.offersCropControl(on: .review),
                      "removing the upload control only makes sense because the "
                      + "review page crops on the rendered collage")
    }

    func testTheUploadSourceMatchesTheRule() {
        let hasCropControl = uploadView.contains("CropOffsetPopover")
            || uploadView.contains("Adjust crop position")
        XCTAssertEqual(hasCropControl,
                       PhotoThumbControls.offersCropControl(on: .upload),
                       hasCropControl
                       ? "the upload page has a crop control again, but the rule says it should not"
                       : "the rule now allows a crop control here, but there is none")
    }
}
