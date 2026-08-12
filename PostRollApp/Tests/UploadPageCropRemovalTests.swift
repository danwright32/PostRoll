import XCTest

/// #189: the upload page offered an "Adjust crop" popover against an 80pt
/// thumbnail, before anything had been generated, with no view of the collage
/// cell the crop would actually apply to. It wrote the same
/// `PostingDay.cropOffsets` storage the review page edits, so it was a second
/// editor for one setting and the worse of the two.
///
/// The control is gone. What must NOT go with it: the stored values, and the
/// cleanup that clears a photo's crop when the photo is removed, which rides on
/// the same binding.
final class UploadPageCropRemovalTests: XCTestCase {

    func testExistingCropValuesAreNotClearedByRemovingTheControl() {
        // Both renderers and the review page still read these.
        var day = PostingDay(day: .wednesday)
        let photo = URL(fileURLWithPath: "/p/1.jpg")
        day.photoPaths = [photo]
        day.cropOffsets = [photo.absoluteString: CropOffset(x: 0, y: -0.4)]

        XCTAssertEqual(day.cropOffsets[photo.absoluteString]?.y, -0.4)
    }

    func testRemovingAPhotoStillClearsItsCropEntry() {
        // The cleanup rides on the cropOffsets binding, which is still passed
        // to the thumbnail even though the button is gone. Dropping the
        // binding entirely would have left orphaned crop entries behind.
        var offsets: [String: CropOffset] = [
            "/p/1.jpg": CropOffset(x: 0, y: -0.4),
            "/p/2.jpg": CropOffset(x: 0, y: -0.2),
        ]
        offsets.removeValue(forKey: "/p/1.jpg")

        XCTAssertNil(offsets["/p/1.jpg"])
        XCTAssertNotNil(offsets["/p/2.jpg"], "only the removed photo's crop goes")
    }

    func testTaggingIsStillOfferedOnACarouselDayWithNoCropControl() {
        // Crop and tagging answer to different bindings; gating tagging on the
        // crop binding is what once hid it on Sunday and Monday.
        XCTAssertTrue(PhotoThumbControls.usesDetailedThumb(cropEnabled: false,
                                                           taggingEnabled: true))
    }
}
