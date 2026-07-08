import XCTest

/// save() and finalizeAdvance() in CaptionReviewView used to duplicate this
/// exact "merge local @State dicts back into ev.days" loop independently.
/// Advancing to Export called finalizeAdvance() but not save(), so an edit
/// only wired into save()'s copy silently never reached ev.days on that
/// route. DayStateMerger is the single shared implementation both call now.
/// This test is the regression pin for that bug class, exercised via the
/// merge itself (the same one finalizeAdvance() calls) rather than the View.
final class DayStateMergerTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/clips/\(name)") }

    func testMergesAllFourFieldSetsIntoMatchingDay() {
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        ev.days["wednesday"] = PostingDay(day: .wednesday)
        ev.days["friday"] = PostingDay(day: .friday)

        DayStateMerger.mergeLocalStateIntoDays(
            &ev,
            collageCropOffsets: ["wednesday": ["a.jpg": CropOffset(x: 0.5, y: 0, scale: 1)]],
            reelCropOffsets: ["wednesday": ["b.jpg": CropOffset(x: 0, y: 0.2, scale: 1)]],
            collageCellOverrides: ["wednesday": [CollageCell(photoPath: "a.jpg", x: 0, y: 0, w: 1, h: 1)]],
            fridayClipOverride: ["friday": [ReelClipOverride(clipPath: url("a.mov").path, order: 0, included: true, trimIn: 0, trimOut: 5)]]
        )

        let wed = ev.days["wednesday"]!
        XCTAssertEqual(wed.collageCropOffsets["a.jpg"]?.x, 0.5)
        XCTAssertEqual(wed.reelCropOffsets["b.jpg"]?.y, 0.2)
        XCTAssertEqual(wed.collageCellOverride?.first?.photoPath, "a.jpg")

        let fri = ev.days["friday"]!
        XCTAssertEqual(fri.fridayClipOverride?.first?.clipPath, url("a.mov").path,
                       "This is the regression pin: a fridayClipOverride edit must survive the shared merge, the same call finalizeAdvance() makes on the Advance-to-Export route.")
    }

    func testEmptyDictsAreNoOpAndDoNotClearExistingDayFields() {
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        var fri = PostingDay(day: .friday)
        fri.fridayClipOverride = [ReelClipOverride(clipPath: url("kept.mov").path, order: 0, included: true, trimIn: 0, trimOut: 5)]
        ev.days["friday"] = fri

        DayStateMerger.mergeLocalStateIntoDays(
            &ev,
            collageCropOffsets: [:],
            reelCropOffsets: [:],
            collageCellOverrides: [:],
            fridayClipOverride: [:]
        )

        XCTAssertEqual(ev.days["friday"]?.fridayClipOverride?.first?.clipPath, url("kept.mov").path,
                       "Merging an empty dict must not clobber a day's existing field it says nothing about.")
    }

    func testSkipsDayKeyNotPresentInEvent() {
        var ev = Event(name: "A", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        // No "friday" day added to ev.days at all.

        DayStateMerger.mergeLocalStateIntoDays(
            &ev,
            collageCropOffsets: [:],
            reelCropOffsets: [:],
            collageCellOverrides: [:],
            fridayClipOverride: ["friday": [ReelClipOverride(clipPath: "/x.mov", order: 0, included: true, trimIn: 0, trimOut: 5)]]
        )

        XCTAssertNil(ev.days["friday"], "Must not fabricate a day entry that doesn't already exist.")
    }
}
