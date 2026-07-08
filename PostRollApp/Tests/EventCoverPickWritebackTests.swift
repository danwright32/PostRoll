import XCTest

/// Phase 2 (#140): the same three call sites EventFridayClipPlanWritebackTests.swift
/// pins for the Friday clip plan (GenerationManager.finishSuccess,
/// CaptionReviewView.generateGraphics, CaptionReviewView.applyRegenResult)
/// also need to persist a freshly-decoded cover pick back onto the saved
/// Event, per day (Thursday and Friday both apply, unlike fridayClipPlan
/// which is Friday-only). Event.applyCoverPick is the single shared
/// implementation all three call.
final class EventCoverPickWritebackTests: XCTestCase {

    private func makeEvent() -> Event {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.days["thursday"] = PostingDay(day: .thursday)
        return event
    }

    func testWritesPickOntoNamedDay() {
        var event = makeEvent()
        let pick = CoverPick(sourcePath: "/photos/picked.jpg", rationale: "sharp soloist")

        event.applyCoverPick(pick, forDay: "thursday")

        XCTAssertEqual(event.days["thursday"]?.coverPick?.sourcePath, "/photos/picked.jpg")
        XCTAssertEqual(event.days["thursday"]?.coverPick?.rationale, "sharp soloist")
    }

    func testNilPickIsANoOp() {
        var event = makeEvent()
        event.days["thursday"]?.coverPick = CoverPick(sourcePath: "/photos/existing.jpg", rationale: "existing")

        event.applyCoverPick(nil, forDay: "thursday")

        XCTAssertEqual(event.days["thursday"]?.coverPick?.sourcePath, "/photos/existing.jpg",
                       "a nil pick (e.g. sticky gate reused a persisted one, or the day has none) must not clobber an existing persisted pick")
    }

    func testNoMatchingDayIsANoOp() {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        let pick = CoverPick(sourcePath: "/x.jpg", rationale: "x")

        event.applyCoverPick(pick, forDay: "friday")

        XCTAssertNil(event.days["friday"], "must not fabricate a day that didn't exist")
    }
}
