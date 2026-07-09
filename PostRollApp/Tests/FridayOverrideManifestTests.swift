import XCTest

/// Pins the manifest PythonBridge sends to render_friday_override.py when
/// the user edits the clip selection manually (reorder/include-exclude/
/// swap, #135). ReelClipOverride has no transition field of its own, so
/// each entry's transition must be carried over from the original AI plan
/// (matched by clip path): a clip the AI never picked (a fresh swap-in)
/// falls back to "cut".
final class FridayOverrideManifestTests: XCTestCase {

    func testOrdersByOrderFieldAndFiltersExcluded() {
        let override = [
            ReelClipOverride(clipPath: "/b.mov", order: 1, included: true, trimIn: 0, trimOut: 2),
            ReelClipOverride(clipPath: "/a.mov", order: 0, included: true, trimIn: 0, trimOut: 2),
            ReelClipOverride(clipPath: "/c.mov", order: 2, included: false, trimIn: 0, trimOut: 2),
        ]

        let manifest = PythonBridge.buildFridayOverrideManifest(override: override, originalPlan: nil)
        let selections = manifest["selections"] as? [[String: Any]]

        XCTAssertEqual(selections?.count, 2, "excluded entry dropped")
        XCTAssertEqual(selections?[0]["clip_path"] as? String, "/a.mov")
        XCTAssertEqual(selections?[1]["clip_path"] as? String, "/b.mov")
    }

    func testCarriesOverTransitionFromOriginalPlanByClipPath() {
        let override = [
            ReelClipOverride(clipPath: "/a.mov", order: 0, included: true, trimIn: 1, trimOut: 4),
        ]
        let originalPlan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: "/a.mov", trimIn: 1, trimOut: 4, transition: .crossfade)],
            rationale: "x"
        )

        let manifest = PythonBridge.buildFridayOverrideManifest(override: override, originalPlan: originalPlan)
        let selections = manifest["selections"] as? [[String: Any]]

        XCTAssertEqual(selections?.first?["transition"] as? String, "crossfade")
    }

    func testSwappedInClipNotInOriginalPlanDefaultsToCut() {
        let override = [
            ReelClipOverride(clipPath: "/new-swap.mov", order: 0, included: true, trimIn: 0, trimOut: 3),
        ]
        let originalPlan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: "/a.mov", trimIn: 1, trimOut: 4, transition: .crossfade)],
            rationale: "x"
        )

        let manifest = PythonBridge.buildFridayOverrideManifest(override: override, originalPlan: originalPlan)
        let selections = manifest["selections"] as? [[String: Any]]

        XCTAssertEqual(selections?.first?["transition"] as? String, "cut")
    }

    func testTrimValuesPassThrough() {
        let override = [
            ReelClipOverride(clipPath: "/a.mov", order: 0, included: true, trimIn: 1.5, trimOut: 4.25),
        ]

        let manifest = PythonBridge.buildFridayOverrideManifest(override: override, originalPlan: nil)
        let selections = manifest["selections"] as? [[String: Any]]

        XCTAssertEqual(selections?.first?["trim_in"] as? Double, 1.5)
        XCTAssertEqual(selections?.first?["trim_out"] as? Double, 4.25)
    }

    // Per-shot crop (plan #148, Phase 2): a manual reorder/trim edit must
    // not silently drop the AI's crop choice, since ReelClipOverride now
    // carries cropX/cropY over from the original plan.
    func testCropValuesPassThrough() {
        let override = [
            ReelClipOverride(clipPath: "/a.mov", order: 0, included: true, trimIn: 1, trimOut: 4,
                             cropX: 0.4, cropY: -0.2),
        ]

        let manifest = PythonBridge.buildFridayOverrideManifest(override: override, originalPlan: nil)
        let selections = manifest["selections"] as? [[String: Any]]

        XCTAssertEqual(selections?.first?["crop_x"] as? Double, 0.4)
        XCTAssertEqual(selections?.first?["crop_y"] as? Double, -0.2)
    }
}
