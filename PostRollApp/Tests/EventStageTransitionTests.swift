import XCTest

/// #103: the photo assignment screen wrote its captured `event` prop back to
/// the store when changing stage. The prop is a snapshot from when the screen
/// was built, so both buttons that change stage silently reverted everything
/// saved since.
///
/// Advance was the damaging one: it called `save()`, which persisted every
/// photo assignment, tag, note and crop offset, and then immediately wrote the
/// pre-assignment snapshot back over it.
final class EventStageTransitionTests: XCTestCase {

    private func event(stage: EventStage, photos: [URL] = []) -> Event {
        var e = Event(name: "Show", org: "Org", venue: "Hall",
                      date: Date(), shootType: .fullShow)
        e.stage = stage
        var day = PostingDay(day: .sunday)
        day.photoPaths = photos
        e.days[DayName.sunday.rawValue] = day
        return e
    }

    func testTheStageIsApplied() {
        let live = event(stage: .ocrDone)
        let moved = EventStageTransition.applying(.photosAssigned,
                                                  toEventWithID: live.id,
                                                  in: [live])
        XCTAssertEqual(moved?.stage, .photosAssigned)
    }

    func testWorkSavedSinceTheScreenOpenedSurvivesTheStageChange() {
        // The exact defect. `stale` is the prop the screen captured, before any
        // photo was assigned. `live` is what save() has since written.
        let stale = event(stage: .ocrDone, photos: [])
        var live = stale
        live.days[DayName.sunday.rawValue]?.photoPaths =
            [URL(fileURLWithPath: "/photos/a.jpg"), URL(fileURLWithPath: "/photos/b.jpg")]

        let moved = EventStageTransition.applying(.assetsGenerated,
                                                  toEventWithID: stale.id,
                                                  in: [live])

        XCTAssertEqual(moved?.days[DayName.sunday.rawValue]?.photoPaths.count, 2,
                       "the stage change must not revert the assignments save() just wrote")
        XCTAssertEqual(moved?.stage, .assetsGenerated)
    }

    func testGoingBackAlsoKeepsTheWork() {
        // The Back button had the same shape, and its own label promises this:
        // "Your photo assignments are saved. Going back won't lose them."
        let stale = event(stage: .photosAssigned, photos: [])
        var live = stale
        live.days[DayName.sunday.rawValue]?.notes = "shot from the back of the house"

        let moved = EventStageTransition.applying(.ocrDone,
                                                  toEventWithID: stale.id,
                                                  in: [live])

        XCTAssertEqual(moved?.days[DayName.sunday.rawValue]?.notes,
                       "shot from the back of the house")
        XCTAssertEqual(moved?.stage, .ocrDone)
    }

    func testAnEventThatIsNoLongerThereReturnsNil() {
        // Deleted while the screen was open. Better to do nothing than to
        // resurrect it from a stale snapshot.
        let gone = event(stage: .ocrDone)
        XCTAssertNil(EventStageTransition.applying(.exported,
                                                   toEventWithID: gone.id,
                                                   in: []))
    }

    func testTheOtherEventsAreNotTouched() {
        let a = event(stage: .ocrDone)
        let b = event(stage: .created)
        let moved = EventStageTransition.applying(.exported, toEventWithID: a.id, in: [a, b])
        XCTAssertEqual(moved?.id, a.id)
        XCTAssertEqual(b.stage, .created)
    }
}
