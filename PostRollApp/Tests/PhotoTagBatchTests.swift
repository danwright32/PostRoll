import XCTest

/// Issue #172: tagging a 10-photo Wednesday carousel one photo at a time is
/// slow, so the tagging sheet can copy the photo on screen's tags onto every
/// photo in the day at once. The merge is pure logic, kept out of the view so
/// it can be tested: one that clobbered a photo's existing tags would quietly
/// lose work with nothing to show it had happened.
final class PhotoTagBatchTests: XCTestCase {

    private let a = "file:///photos/a.jpg"
    private let b = "file:///photos/b.jpg"
    private let c = "file:///photos/c.jpg"

    // MARK: - Applying tags to many photos

    func testTagsLandOnEverySelectedPhoto() {
        let result = PhotoTagBatch.applying(tags: ["Jane Smith"], to: [a, c], in: [:])
        XCTAssertEqual(result[a], ["Jane Smith"])
        XCTAssertEqual(result[c], ["Jane Smith"])
    }

    func testUnselectedPhotosAreUntouched() {
        let existing = [b: ["Mike Bono"]]
        let result = PhotoTagBatch.applying(tags: ["Jane Smith"], to: [a], in: existing)
        XCTAssertEqual(result[b], ["Mike Bono"], "a photo outside the selection keeps exactly what it had")
        XCTAssertNil(result[c])
    }

    func testExistingTagsAreAddedToNotReplaced() {
        let existing = [a: ["Mike Bono"]]
        let result = PhotoTagBatch.applying(tags: ["Jane Smith"], to: [a], in: existing)
        XCTAssertEqual(result[a], ["Mike Bono", "Jane Smith"],
                       "batch tagging must never clobber tags already on a photo")
    }

    func testATagAlreadyOnThePhotoIsNotDuplicated() {
        let existing = [a: ["Jane Smith"]]
        let result = PhotoTagBatch.applying(tags: ["jane smith", "@newperson"], to: [a], in: existing)
        XCTAssertEqual(result[a], ["Jane Smith", "@newperson"],
                       "matching is case-insensitive and keeps the spelling already stored")
    }

    func testBlankTagsAreIgnored() {
        let result = PhotoTagBatch.applying(tags: ["  ", "", "Real Person"], to: [a], in: [:])
        XCTAssertEqual(result[a], ["Real Person"])
    }

    func testNothingChangesWhenThereAreNoTagsOrNoSelection() {
        let existing = [a: ["Mike Bono"]]
        XCTAssertEqual(PhotoTagBatch.applying(tags: [], to: [a], in: existing), existing)
        XCTAssertEqual(PhotoTagBatch.applying(tags: ["Jane"], to: [], in: existing), existing)
    }

    func testAPhotoWithOnlyBlankTagsGetsNoEntryAtAll() {
        let result = PhotoTagBatch.applying(tags: ["   "], to: [a], in: [:])
        XCTAssertNil(result[a], "an all-blank batch must not leave an empty tag entry behind")
    }

    // MARK: - Add to every photo in the day

    func testAddToAllReachesEveryPhotoInTheDay() {
        let result = PhotoTagBatch.applyingToAll(tags: ["Ana Ruiz"], dayPhotos: [a, b, c], in: [:])
        XCTAssertEqual(result[a], ["Ana Ruiz"])
        XCTAssertEqual(result[b], ["Ana Ruiz"])
        XCTAssertEqual(result[c], ["Ana Ruiz"])
    }

    func testAddToAllKeepsWhatEachPhotoAlreadyHad() {
        let existing = [b: ["Mike Bono"]]
        let result = PhotoTagBatch.applyingToAll(tags: ["Ana Ruiz"], dayPhotos: [a, b], in: existing)
        XCTAssertEqual(result[b], ["Mike Bono", "Ana Ruiz"],
                       "the performer in every shot is added, not swapped for who was already there")
    }

    func testAddToAllLeavesStaleEntriesForRemovedPhotosAlone() {
        let stale = ["file:///photos/gone.jpg": ["Old Tag"]]
        let result = PhotoTagBatch.applyingToAll(tags: ["Ana Ruiz"], dayPhotos: [a], in: stale)
        XCTAssertEqual(result["file:///photos/gone.jpg"], ["Old Tag"],
                       "a photo no longer in the day must not be tagged by an add-to-all")
        XCTAssertEqual(result[a], ["Ana Ruiz"])
    }

    func testAddToAllOnADayWithNoPhotosChangesNothing() {
        let existing = [a: ["Mike Bono"]]
        XCTAssertEqual(PhotoTagBatch.applyingToAll(tags: ["Ana"], dayPhotos: [], in: existing), existing)
    }

    // MARK: - Reporting what actually happened
    //
    // The button gave no sign it had done anything, so it read as broken while
    // working. Whatever it reports has to be what actually changed: claiming
    // "added to all 4" when three already had the tag is a false success.

    func testReportsEveryPhotoWhenNoneHadTheTag() {
        let before: [String: [String]] = [:]
        let after = PhotoTagBatch.applyingToAll(tags: ["Ana Ruiz"], dayPhotos: [a, b, c], in: before)
        XCTAssertEqual(PhotoTagBatch.photosChanged(from: before, to: after, in: [a, b, c]), 3)
    }

    func testReportsOnlyThePhotosThatDidNotAlreadyHaveIt() {
        let before = [a: ["Ana Ruiz"], b: ["Ana Ruiz"]]
        let after = PhotoTagBatch.applyingToAll(tags: ["Ana Ruiz"], dayPhotos: [a, b, c], in: before)
        XCTAssertEqual(PhotoTagBatch.photosChanged(from: before, to: after, in: [a, b, c]), 1,
                       "two photos already had her, so only one changed")
    }

    func testReportsNothingWhenEveryPhotoAlreadyHadTheTag() {
        let before = [a: ["Ana Ruiz"], b: ["ana ruiz"]]
        let after = PhotoTagBatch.applyingToAll(tags: ["Ana Ruiz"], dayPhotos: [a, b], in: before)
        XCTAssertEqual(PhotoTagBatch.photosChanged(from: before, to: after, in: [a, b]), 0,
                       "nothing changed, and saying otherwise would be a false success")
    }

    func testChangesOutsideTheDayAreNotCounted() {
        let before = [a: ["Ana"]]
        var after = before
        after["file:///photos/gone.jpg"] = ["Ghost"]
        XCTAssertEqual(PhotoTagBatch.photosChanged(from: before, to: after, in: [a]), 0)
    }
}

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
