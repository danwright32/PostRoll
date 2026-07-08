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
}
