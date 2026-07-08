import XCTest

/// PostingDay.rebindingClips carries clip references (fridayClipPlan
/// selections, fridayClipOverride entries) to a new URL after MediaReclaim
/// copies the file into app storage. Same bug class collage layouts hit
/// before rebasing existed (feedback_layout_json_paths_go_stale), now applied
/// to clips.
final class PostingDayClipTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/clips/\(name)") }

    func testRebindCarriesClipPathsPlanAndOverrideToNewURL() {
        let old = url("old/a.mov"), b = url("b.mov")
        let new = URL(fileURLWithPath: "/storage/a.mov")
        var day = PostingDay(day: .friday)
        day.clipPaths = [old, b]
        day.fridayClipPlan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: old.path, trimIn: 1, trimOut: 4, transition: .crossfade)],
            rationale: "opens strong"
        )
        day.fridayClipOverride = [
            ReelClipOverride(clipPath: old.path, order: 0, included: true, trimIn: 1, trimOut: 4)
        ]

        let result = day.rebindingClips([old: new])

        XCTAssertEqual(result.clipPaths, [new, b], "URL swapped in place, order kept")
        XCTAssertEqual(result.fridayClipPlan?.selections.first?.clipPath, new.path)
        XCTAssertEqual(result.fridayClipOverride?.first?.clipPath, new.path)
    }

    func testRebindClipsEmptyIsNoOp() {
        let a = url("a.mov")
        var day = PostingDay(day: .friday)
        day.clipPaths = [a]
        XCTAssertEqual(day.rebindingClips([:]).clipPaths, [a])
    }

    func testRebindClipsLeavesUnrelatedOverrideEntriesUntouched() {
        let old = url("old/a.mov"), untouched = url("b.mov")
        let new = URL(fileURLWithPath: "/storage/a.mov")
        var day = PostingDay(day: .friday)
        day.clipPaths = [old, untouched]
        day.fridayClipOverride = [
            ReelClipOverride(clipPath: old.path, order: 0, included: true, trimIn: 0, trimOut: 5),
            ReelClipOverride(clipPath: untouched.path, order: 1, included: true, trimIn: 0, trimOut: 5),
        ]

        let result = day.rebindingClips([old: new])

        XCTAssertEqual(result.fridayClipOverride?[0].clipPath, new.path)
        XCTAssertEqual(result.fridayClipOverride?[1].clipPath, untouched.path, "not in remap, path unchanged")
    }

    // addingClips backs the Friday clip import flow (#135): storedClip-copied
    // URLs get appended to clipPaths so importing in multiple batches doesn't
    // drop earlier picks.
    func testAddingClipsAppendsToExistingClipPaths() {
        let a = url("a.mov")
        var day = PostingDay(day: .friday)
        day.clipPaths = [a]

        let b = url("b.mov"), c = url("c.mov")
        let result = day.addingClips([b, c])

        XCTAssertEqual(result.clipPaths, [a, b, c])
    }

    func testAddingClipsEmptyIsNoOp() {
        let a = url("a.mov")
        var day = PostingDay(day: .friday)
        day.clipPaths = [a]

        XCTAssertEqual(day.addingClips([]).clipPaths, [a])
    }

    // effectiveFridayOverride backs the manual editor (#135): before the
    // user has ever touched reorder/include-exclude/swap, the editor shows
    // the AI's own plan as its starting point rather than an empty list.
    func testEffectiveFridayOverrideDerivesFromPlanWhenNoOverrideYet() {
        var day = PostingDay(day: .friday)
        day.fridayClipPlan = FridayClipPlan(
            selections: [
                FridayClipSelection(clipPath: "/a.mov", trimIn: 0, trimOut: 3, transition: .cut),
                FridayClipSelection(clipPath: "/b.mov", trimIn: 1, trimOut: 4, transition: .crossfade),
            ],
            rationale: "x"
        )

        let effective = day.effectiveFridayOverride

        XCTAssertEqual(effective.count, 2)
        XCTAssertEqual(effective[0].clipPath, "/a.mov")
        XCTAssertEqual(effective[0].order, 0)
        XCTAssertTrue(effective[0].included)
        XCTAssertEqual(effective[1].clipPath, "/b.mov")
        XCTAssertEqual(effective[1].order, 1)
    }

    func testEffectiveFridayOverrideUsesExistingOverrideOnceUserHasEdited() {
        var day = PostingDay(day: .friday)
        day.fridayClipPlan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: "/a.mov", trimIn: 0, trimOut: 3, transition: .cut)],
            rationale: "x"
        )
        day.fridayClipOverride = [
            ReelClipOverride(clipPath: "/a.mov", order: 0, included: false, trimIn: 0, trimOut: 3),
        ]

        XCTAssertEqual(day.effectiveFridayOverride, day.fridayClipOverride,
                       "an existing user edit must win over re-deriving from the AI plan")
    }

    func testEffectiveFridayOverrideEmptyWhenNoPlanAndNoOverride() {
        let day = PostingDay(day: .friday)
        XCTAssertTrue(day.effectiveFridayOverride.isEmpty)
    }
}
