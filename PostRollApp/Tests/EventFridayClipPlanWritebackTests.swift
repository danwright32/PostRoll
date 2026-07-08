import XCTest

/// Phase 3 (#134): three call sites (GenerationManager.finishSuccess,
/// CaptionReviewView.generateGraphics, CaptionReviewView.applyRegenResult)
/// each need to persist a freshly-decoded Friday clip plan back onto the
/// saved Event after a generation run, otherwise Stage 2's plan is
/// computed by Python and then thrown away, and 3e's caption frame
/// extraction (which reads it back out of the manifest on the NEXT run)
/// would only ever see a stale or empty plan. Event.applyFridayClipPlan is
/// the single shared implementation all three call.
final class EventFridayClipPlanWritebackTests: XCTestCase {

    private func makeEvent() -> Event {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.days["friday"] = PostingDay(day: .friday)
        return event
    }

    func testWritesPlanOntoFridayDay() {
        var event = makeEvent()
        let plan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: "/clips/a.mov", trimIn: 1, trimOut: 4, transition: .crossfade)],
            rationale: "opens strong"
        )

        event.applyFridayClipPlan(plan)

        XCTAssertEqual(event.days["friday"]?.fridayClipPlan?.rationale, "opens strong")
        XCTAssertEqual(event.days["friday"]?.fridayClipPlan?.selections.first?.clipPath, "/clips/a.mov")
    }

    func testNilPlanIsANoOp() {
        var event = makeEvent()
        event.days["friday"]?.fridayClipPlan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: "/clips/existing.mov", trimIn: 0, trimOut: 2, transition: .cut)],
            rationale: "existing"
        )

        event.applyFridayClipPlan(nil)

        XCTAssertEqual(event.days["friday"]?.fridayClipPlan?.rationale, "existing",
                       "a nil plan (e.g. no reel attempted this run) must not clobber an existing persisted plan")
    }

    func testNoFridayDayIsANoOp() {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        let plan = FridayClipPlan(selections: [], rationale: "x")

        event.applyFridayClipPlan(plan)

        XCTAssertNil(event.days["friday"], "must not fabricate a Friday day that didn't exist")
    }
}
