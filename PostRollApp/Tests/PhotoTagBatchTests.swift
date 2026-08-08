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
}
