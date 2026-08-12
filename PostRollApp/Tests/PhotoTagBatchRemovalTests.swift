import XCTest

/// #187: batch tagging could only ever add. Tagging ten photos with the wrong
/// person took one click and cost ten per-photo popovers to undo, which is
/// precisely the slowness batch tagging was built to remove.
final class PhotoTagBatchRemovalTests: XCTestCase {

    private let photos = ["/p/1.jpg", "/p/2.jpg", "/p/3.jpg"]

    func testTheTagIsRemovedFromEverySelectedPhoto() {
        let before = ["/p/1.jpg": ["Safa", "Ladibree"], "/p/2.jpg": ["Safa"]]
        let after = PhotoTagBatch.removing(tags: ["Safa"],
                                           from: ["/p/1.jpg", "/p/2.jpg"],
                                           in: before)
        XCTAssertEqual(after["/p/1.jpg"], ["Ladibree"])
        XCTAssertNil(after["/p/2.jpg"], "a photo with nothing left carries no entry")
    }

    func testPhotosOutsideTheSelectionAreUntouched() {
        let before = ["/p/1.jpg": ["Safa"], "/p/3.jpg": ["Safa"]]
        let after = PhotoTagBatch.removing(tags: ["Safa"], from: ["/p/1.jpg"], in: before)
        XCTAssertEqual(after["/p/3.jpg"], ["Safa"])
    }

    func testOtherTagsOnTheSamePhotoSurvive() {
        let before = ["/p/1.jpg": ["Safa", "Pete White", "Ladibree"]]
        let after = PhotoTagBatch.removing(tags: ["Pete White"], from: ["/p/1.jpg"], in: before)
        XCTAssertEqual(after["/p/1.jpg"], ["Safa", "Ladibree"])
    }

    func testMatchingIgnoresCase() {
        // Stored as spelled, so removing must not depend on matching the case.
        let before = ["/p/1.jpg": ["Safa.WAV"]]
        let after = PhotoTagBatch.removing(tags: ["safa.wav"], from: ["/p/1.jpg"], in: before)
        XCTAssertNil(after["/p/1.jpg"])
    }

    func testRemovingATagAPhotoDoesNotHaveChangesNothing() {
        let before = ["/p/1.jpg": ["Safa"]]
        XCTAssertEqual(PhotoTagBatch.removing(tags: ["Nobody"], from: photos, in: before),
                       before)
    }

    func testAnEmptyRequestChangesNothing() {
        let before = ["/p/1.jpg": ["Safa"]]
        XCTAssertEqual(PhotoTagBatch.removing(tags: [], from: photos, in: before), before)
        XCTAssertEqual(PhotoTagBatch.removing(tags: ["  "], from: photos, in: before), before)
        XCTAssertEqual(PhotoTagBatch.removing(tags: ["Safa"], from: [], in: before), before)
    }

    func testRemovingSeveralTagsAtOnce() {
        let before = ["/p/1.jpg": ["Safa", "Pete White", "Ladibree"]]
        let after = PhotoTagBatch.removing(tags: ["Safa", "Ladibree"],
                                           from: ["/p/1.jpg"], in: before)
        XCTAssertEqual(after["/p/1.jpg"], ["Pete White"])
    }

    func testAddThenRemoveReturnsToWhereItStarted() {
        // The whole point: a batch applied by mistake is reversible in one go.
        let start = ["/p/1.jpg": ["Ladibree"]]
        let added = PhotoTagBatch.applying(tags: ["Safa"], to: photos, in: start)
        let back = PhotoTagBatch.removing(tags: ["Safa"], from: photos, in: added)
        XCTAssertEqual(back, start)
    }

    func testTheCountReportsPhotosActuallyChanged() {
        // Same discipline as the add: reporting three when only one had the
        // tag is a success message for something that did not happen.
        let before = ["/p/1.jpg": ["Safa"], "/p/2.jpg": ["Ladibree"]]
        let after = PhotoTagBatch.removing(tags: ["Safa"], from: photos, in: before)
        XCTAssertEqual(PhotoTagBatch.photosChanged(from: before, to: after, in: photos), 1)
    }
}
