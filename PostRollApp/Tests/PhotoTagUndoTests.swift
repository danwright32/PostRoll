import XCTest

/// The Undo state machine the tagging sheet drives (#187).
final class PhotoTagUndoTests: XCTestCase {

    private let before = ["/p/1.jpg": ["Safa"]]

    func testNothingIsOfferedBeforeABatchRuns() {
        XCTAssertFalse(PhotoTagUndo().isAvailable)
    }

    func testABatchThatChangedSomethingCanBeUndone() {
        var undo = PhotoTagUndo()
        undo.record(before: before, photosChanged: 2)
        XCTAssertTrue(undo.isAvailable)
        XCTAssertEqual(undo.take(), before)
    }

    func testABatchThatChangedNothingOffersNoUndo() {
        // Offering it would imply something happened.
        var undo = PhotoTagUndo()
        undo.record(before: before, photosChanged: 0)
        XCTAssertFalse(undo.isAvailable)
        XCTAssertNil(undo.take())
    }

    func testUndoIsConsumedSoItCannotBeAppliedTwice() {
        var undo = PhotoTagUndo()
        undo.record(before: before, photosChanged: 1)
        XCTAssertEqual(undo.take(), before)
        XCTAssertNil(undo.take(), "a second Undo would restore stale tags")
        XCTAssertFalse(undo.isAvailable)
    }

    func testMovingToAnotherPhotoClearsIt() {
        // An Undo button under a different photo is a promise about work the
        // person can no longer see.
        var undo = PhotoTagUndo()
        undo.record(before: before, photosChanged: 1)
        undo.clear()
        XCTAssertFalse(undo.isAvailable)
    }

    func testASecondBatchReplacesWhatTheFirstWouldHaveRestored() {
        var undo = PhotoTagUndo()
        undo.record(before: before, photosChanged: 1)
        let later = ["/p/1.jpg": ["Safa", "Ladibree"]]
        undo.record(before: later, photosChanged: 1)
        XCTAssertEqual(undo.take(), later, "Undo must reverse the LAST batch")
    }

    func testANoOpBatchAfterARealOneDoesNotLeaveAStaleUndo() {
        // Otherwise Undo would silently reverse an older batch than the one
        // the message on screen is describing.
        var undo = PhotoTagUndo()
        undo.record(before: before, photosChanged: 1)
        undo.record(before: ["/p/1.jpg": ["Whatever"]], photosChanged: 0)
        XCTAssertFalse(undo.isAvailable)
    }
}
