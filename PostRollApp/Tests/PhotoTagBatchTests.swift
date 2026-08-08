import XCTest

/// Issue #172: tagging a 10-photo Wednesday carousel one photo at a time is
/// slow, so several photos can be selected and tagged in one pass. The
/// selection and the merge are pure logic, kept out of the view so both can
/// be tested: a merge that clobbered a photo's existing tags, or a selection
/// that drifted after photos were removed, would quietly lose Dan's work.
final class PhotoTagBatchTests: XCTestCase {

    private let a = "file:///photos/a.jpg"
    private let b = "file:///photos/b.jpg"
    private let c = "file:///photos/c.jpg"
    private let d = "file:///photos/d.jpg"
    private var ordered: [String] { [a, b, c, d] }

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

    // MARK: - Selection

    func testToggleAddsThenRemoves() {
        var sel = PhotoSelection()
        sel.toggle(b)
        XCTAssertEqual(sel.keys, [b])
        sel.toggle(b)
        XCTAssertTrue(sel.keys.isEmpty)
    }

    func testShiftExtendsTheRangeForwardFromTheLastPhotoClicked() {
        var sel = PhotoSelection()
        sel.toggle(a)
        sel.extend(to: c, in: ordered)
        XCTAssertEqual(sel.keys, [a, b, c], "the range is inclusive of both ends")
        XCTAssertFalse(sel.keys.contains(d))
    }

    func testShiftExtendsTheRangeBackwardsToo() {
        var sel = PhotoSelection()
        sel.toggle(d)
        sel.extend(to: b, in: ordered)
        XCTAssertEqual(sel.keys, [b, c, d])
    }

    func testExtendingWithNothingSelectedYetJustSelectsThatPhoto() {
        var sel = PhotoSelection()
        sel.extend(to: c, in: ordered)
        XCTAssertEqual(sel.keys, [c])
    }

    func testExtendingKeepsWhatWasAlreadySelectedElsewhere() {
        var sel = PhotoSelection()
        sel.toggle(a)
        sel.toggle(c)          // anchor is now c
        sel.extend(to: d, in: ordered)
        XCTAssertEqual(sel.keys, [a, c, d], "an earlier pick outside the new range survives")
    }

    // MARK: - Degenerate input

    func testExtendingToAPhotoThatIsNoLongerInTheDayIsIgnored() {
        var sel = PhotoSelection()
        sel.toggle(a)
        sel.extend(to: "file:///photos/gone.jpg", in: ordered)
        XCTAssertEqual(sel.keys, [a], "a stale key must not wipe or corrupt the selection")
    }

    func testSelectionDropsPhotosRemovedFromTheDay() {
        var sel = PhotoSelection()
        sel.toggle(a)
        sel.toggle(c)
        sel.prune(to: [a, b])
        XCTAssertEqual(sel.keys, [a], "a deleted photo must not stay selected and get tagged later")
    }

    func testPruningAlsoDropsAStaleAnchor() {
        var sel = PhotoSelection()
        sel.toggle(c)
        sel.prune(to: [a, b])
        sel.extend(to: b, in: [a, b])
        XCTAssertEqual(sel.keys, [b], "with the anchor gone, extend selects just the target")
    }

    func testClearEmptiesTheSelection() {
        var sel = PhotoSelection()
        sel.toggle(a)
        sel.toggle(b)
        sel.clear()
        XCTAssertTrue(sel.keys.isEmpty)
    }
}
