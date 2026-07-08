import XCTest

/// Phase 3 (#134): generate_media.py's Friday day_result now carries a
/// nested friday_clip_plan object alongside its string-valued asset paths
/// (e.g. "reel"). The pre-existing decode cast `dayDict as? [String: String]`
/// fails outright on a dict with a mixed String/dict value shape, which
/// would have silently dropped Friday's "reel" path entirely the moment
/// clips were used, not just the plan. Pins the fix: string paths and the
/// clip plan parse independently from the same mixed-type day dict.
final class PreviewGenerationClipPlanDecodeTests: XCTestCase {

    func testParsesStringPathsAlongsideNestedClipPlan() {
        let dayDict: [String: Any] = [
            "reel": "/tmp/reel.mp4",
            "friday_clip_plan": [
                "selections": [
                    ["clip_path": "/clips/a.mov", "trim_in": 1.0, "trim_out": 4.5, "transition": "crossfade"],
                ],
                "rationale": "opens strong",
            ],
        ]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in true })

        XCTAssertEqual(parsed.paths, ["reel": "/tmp/reel.mp4"])
        XCTAssertEqual(parsed.fridayClipPlan?.rationale, "opens strong")
        XCTAssertEqual(parsed.fridayClipPlan?.selections.first?.clipPath, "/clips/a.mov")
        XCTAssertEqual(parsed.fridayClipPlan?.selections.first?.transition, .crossfade)
    }

    func testDayDictWithNoClipPlanParsesPathsOnly() {
        let dayDict: [String: Any] = ["story": "/tmp/story.png"]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in true })

        XCTAssertEqual(parsed.paths, ["story": "/tmp/story.png"])
        XCTAssertNil(parsed.fridayClipPlan)
    }

    func testNonExistentPathIsFilteredOut() {
        let dayDict: [String: Any] = ["reel": "/tmp/gone.mp4"]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in false })

        XCTAssertTrue(parsed.paths.isEmpty)
    }

    func testMalformedClipPlanIsIgnoredNotThrown() {
        let dayDict: [String: Any] = [
            "reel": "/tmp/reel.mp4",
            "friday_clip_plan": ["selections": "not-a-list"],
        ]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in true })

        XCTAssertEqual(parsed.paths, ["reel": "/tmp/reel.mp4"])
        XCTAssertNil(parsed.fridayClipPlan)
    }
}
