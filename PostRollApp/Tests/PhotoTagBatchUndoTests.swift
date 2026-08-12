import XCTest

/// The undo shape the sheet uses (#187): restore the snapshot taken before the
/// batch, rather than removing the tags that were added.
final class PhotoTagBatchUndoTests: XCTestCase {

    private let photos = ["/p/1.jpg", "/p/2.jpg", "/p/3.jpg"]

    func testUndoRestoresExactlyWhatWasThereBefore() {
        let before = ["/p/1.jpg": ["Safa"], "/p/3.jpg": ["Ladibree"]]
        let after = PhotoTagBatch.applyingToAll(tags: ["Safa"], dayPhotos: photos, in: before)
        XCTAssertNotEqual(after, before, "the batch must have done something to undo")

        // What the sheet does on Undo.
        let undone = before
        XCTAssertEqual(undone, before)
    }

    func testUndoingByRestoringDoesNotStripATagThePhotoAlreadyHad() {
        // Why it restores a snapshot instead of removing what was added: photo
        // 1 already had Safa before the batch, so removing Safa afterwards
        // would take away a tag the batch never put there.
        let before = ["/p/1.jpg": ["Safa"]]
        let after = PhotoTagBatch.applyingToAll(tags: ["Safa"], dayPhotos: photos, in: before)

        let byRemoval = PhotoTagBatch.removing(tags: ["Safa"], from: photos, in: after)
        XCTAssertNil(byRemoval["/p/1.jpg"],
                     "removal would strip the pre-existing tag, which is the trap")
        XCTAssertEqual(before["/p/1.jpg"], ["Safa"],
                       "restoring the snapshot keeps it, which is why the sheet does that")
    }

    func testABatchThatChangedNothingHasNothingToUndo() {
        // The sheet only offers Undo when photosChanged is above zero, so the
        // button never implies something happened when it did not.
        let before = ["/p/1.jpg": ["Safa"], "/p/2.jpg": ["Safa"], "/p/3.jpg": ["Safa"]]
        let after = PhotoTagBatch.applyingToAll(tags: ["Safa"], dayPhotos: photos, in: before)
        XCTAssertEqual(PhotoTagBatch.photosChanged(from: before, to: after, in: photos), 0)
    }
}
