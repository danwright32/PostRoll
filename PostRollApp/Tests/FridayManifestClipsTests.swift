import XCTest

/// Phase 3 (#134): a Friday day with clips imported but no photos/raw/edited
/// stills was silently dropped from both manifest builders before this
/// feature: the inclusion guard only checked photo-shaped fields, so Stage
/// 1/2 could never fire regardless of what was stored on PostingDay. Pins
/// the widened guard and the new clips/duck-setting entries in both
/// buildMediaManifest (used by generate_media.py) and buildManifest (used
/// by generate_week.py, the caption pipeline).
final class FridayManifestClipsTests: XCTestCase {

    private func makeEvent(friday: PostingDay) -> Event {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.ocrResult = OCRResult(performers: [])
        event.days["friday"] = friday
        return event
    }

    private func clipsOnlyFriday() -> PostingDay {
        var day = PostingDay(day: .friday)
        day.clipPaths = [URL(fileURLWithPath: "/clips/a.mov"), URL(fileURLWithPath: "/clips/b.mov")]
        return day
    }

    // MARK: - buildMediaManifest (generate_media.py / preview generation)

    func testBuildMediaManifestIncludesFridayWithClipsOnly() async {
        let event = makeEvent(friday: clipsOnlyFriday())
        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        let days = manifest["days"] as? [String: Any]
        let friday = days?["friday"] as? [String: Any]
        XCTAssertNotNil(friday, "a Friday day with only clipPaths set must survive the inclusion guard")
        let clips = friday?["clips"] as? [String]
        XCTAssertEqual(clips, ["/clips/a.mov", "/clips/b.mov"])
    }

    func testBuildMediaManifestExcludesFridayWithNoPhotosAndNoClips() async {
        let event = makeEvent(friday: PostingDay(day: .friday))
        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        let days = manifest["days"] as? [String: Any]
        XCTAssertNil(days?["friday"], "an empty Friday day (no photos, no clips) stays excluded")
    }

    func testBuildMediaManifestIncludesDuckSettingsForFriday() async {
        var day = clipsOnlyFriday()
        day.fridayAudioDuckDB = -18.0
        day.fridayAudioMuted = true
        let event = makeEvent(friday: day)
        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        let friday = (manifest["days"] as? [String: Any])?["friday"] as? [String: Any]
        XCTAssertEqual(friday?["clip_duck_db"] as? Double, -18.0)
        XCTAssertEqual(friday?["clip_audio_muted"] as? Bool, true)
    }

    // MARK: - buildManifest (generate_week.py / caption pipeline)

    func testBuildManifestIncludesFridayWithClipsOnly() async throws {
        let event = makeEvent(friday: clipsOnlyFriday())
        let manifest = try await PythonBridge.shared.buildManifest(event: event)

        let days = manifest["days"] as? [String: Any]
        let friday = days?["friday"] as? [String: Any]
        XCTAssertNotNil(friday, "a Friday day with only clipPaths set must survive the inclusion guard")
        let clips = friday?["clips"] as? [String]
        XCTAssertEqual(clips, ["/clips/a.mov", "/clips/b.mov"])
    }

    func testBuildManifestExcludesFridayWithNoPhotosAndNoClips() async throws {
        let event = makeEvent(friday: PostingDay(day: .friday))
        let manifest = try await PythonBridge.shared.buildManifest(event: event)

        let days = manifest["days"] as? [String: Any]
        XCTAssertNil(days?["friday"])
    }

    func testBuildManifestIncludesPersistedClipPlanForCaptionFrameExtraction() async throws {
        var day = clipsOnlyFriday()
        day.fridayClipPlan = FridayClipPlan(
            selections: [
                FridayClipSelection(clipPath: "/clips/a.mov", trimIn: 1.0, trimOut: 4.5, transition: .crossfade),
            ],
            rationale: "opens strong"
        )
        let event = makeEvent(friday: day)
        let manifest = try await PythonBridge.shared.buildManifest(event: event)

        let friday = (manifest["days"] as? [String: Any])?["friday"] as? [String: Any]
        let clipsPlan = friday?["clips_plan"] as? [String: Any]
        XCTAssertNotNil(clipsPlan, "persisted fridayClipPlan must reach generate_week.py so it can re-extract frames without redoing Stage 1/2")
        let selections = clipsPlan?["selections"] as? [[String: Any]]
        XCTAssertEqual(selections?.first?["clip_path"] as? String, "/clips/a.mov")
        XCTAssertEqual(selections?.first?["trim_in"] as? Double, 1.0)
        XCTAssertEqual(selections?.first?["trim_out"] as? Double, 4.5)
        XCTAssertEqual(selections?.first?["transition"] as? String, "crossfade")
    }
}
