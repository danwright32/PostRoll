import XCTest

/// Phase 2 (#140): generate_media.py's Thursday/Friday day_result now carries
/// a nested cover_pick object (source_path + rationale) alongside its
/// string-valued asset paths (e.g. "cover", "reel"), the same mixed-type
/// shape friday_clip_plan already introduced. Mirrors
/// PreviewGenerationClipPlanDecodeTests.swift's coverage of that same
/// parsing boundary.
final class PreviewGenerationCoverPickDecodeTests: XCTestCase {

    func testParsesStringPathsAlongsideNestedCoverPick() {
        let dayDict: [String: Any] = [
            "cover": "/tmp/cover.png",
            "cover_pick": ["source_path": "/tmp/picked.jpg", "rationale": "sharp soloist"],
        ]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in true })

        XCTAssertEqual(parsed.paths, ["cover": "/tmp/cover.png"])
        XCTAssertEqual(parsed.coverPick?.sourcePath, "/tmp/picked.jpg")
        XCTAssertEqual(parsed.coverPick?.rationale, "sharp soloist")
    }

    func testDayDictWithNoCoverPickParsesPathsOnly() {
        let dayDict: [String: Any] = ["story": "/tmp/story.png"]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in true })

        XCTAssertEqual(parsed.paths, ["story": "/tmp/story.png"])
        XCTAssertNil(parsed.coverPick)
    }

    func testMalformedCoverPickIsIgnoredNotThrown() {
        let dayDict: [String: Any] = [
            "cover": "/tmp/cover.png",
            "cover_pick": ["source_path": 42],
        ]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in true })

        XCTAssertEqual(parsed.paths, ["cover": "/tmp/cover.png"])
        XCTAssertNil(parsed.coverPick)
    }

    func testCoverPickAndFridayClipPlanParseIndependently() {
        let dayDict: [String: Any] = [
            "reel": "/tmp/reel.mp4",
            "friday_clip_plan": [
                "selections": [
                    ["clip_path": "/clips/a.mov", "trim_in": 1.0, "trim_out": 4.5, "transition": "cut"],
                ],
                "rationale": "opens strong",
            ],
            "cover_pick": ["source_path": "/tmp/cover_frame.jpg", "rationale": "strong wide shot"],
        ]

        let parsed = PythonBridge.parsePreviewDayEntry(dayDict, fileExists: { _ in true })

        XCTAssertEqual(parsed.paths, ["reel": "/tmp/reel.mp4"])
        XCTAssertEqual(parsed.fridayClipPlan?.rationale, "opens strong")
        XCTAssertEqual(parsed.coverPick?.sourcePath, "/tmp/cover_frame.jpg")
    }
}
