import XCTest

/// Pins the pure logic behind PythonBridge.runCoverRegeneration (#141): the
/// subprocess call itself isn't unit-testable (same as runBlogPhotoSwap,
/// runCaptionRevision, and every other thin Python-shelling wrapper in this
/// file, none of which have direct tests), but the manifest it builds and
/// the JSON it parses back are pure and worth pinning directly, the same
/// way parsePreviewDayEntry is tested apart from runPreviewGeneration.
final class CoverRegenerationManifestTests: XCTestCase {

    private func makeEvent(day: PostingDay, coverPath: String? = "/preview/thursday/cover.png") -> Event {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.days[day.day.rawValue] = day
        if let coverPath {
            event.previewMediaPaths[day.day.rawValue] = ["cover": coverPath]
        }
        return event
    }

    // MARK: - buildCoverManifest

    func testReturnsNilWhenDayDoesNotExist() {
        let event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        XCTAssertNil(PythonBridge.buildCoverManifest(event: event, day: .thursday, overrideSource: nil))
    }

    func testReturnsNilWhenNoExistingCoverPath() {
        var day = PostingDay(day: .thursday)
        day.photoPaths = [URL(fileURLWithPath: "/photos/a.jpg")]
        let event = makeEvent(day: day, coverPath: nil)
        XCTAssertNil(PythonBridge.buildCoverManifest(event: event, day: .thursday, overrideSource: nil))
    }

    /// The manifest carries no `photos` any more (#961).
    ///
    /// They were Thursday's cover candidates, and Thursday has no cover, so
    /// `generate_cover.py` reads nothing out of them. This replaces the test
    /// that asserted they were sent: its whole content was the key being
    /// removed, and the shared bridge payload contract no longer declares it,
    /// which is what fails if one side changes without the other.
    func testTheManifestDoesNotCarryPhotosNobodyReads() {
        var day = PostingDay(day: .friday)
        day.photoPaths = [URL(fileURLWithPath: "/photos/a.jpg"), URL(fileURLWithPath: "/photos/b.jpg")]
        let event = makeEvent(day: day, coverPath: "/preview/friday/cover.png")

        let manifest = PythonBridge.buildCoverManifest(event: event, day: .friday, overrideSource: nil)

        XCTAssertEqual(manifest?["day"] as? String, "friday")
        XCTAssertEqual(manifest?["output_path"] as? String, "/preview/friday/cover.png")
        let dayInfo = manifest?["day_info"] as? [String: Any]
        XCTAssertNil(dayInfo?["photos"],
                     "the day's photographs are sent to a reader that no longer exists")
        XCTAssertNil(manifest?["override_source"])
    }

    func testFridayManifestCarriesPersistedClipsPlan() {
        var day = PostingDay(day: .friday)
        day.fridayClipPlan = FridayClipPlan(
            selections: [FridayClipSelection(clipPath: "/clips/a.mov", trimIn: 1.0, trimOut: 4.5, transition: .crossfade)],
            rationale: "opens strong"
        )
        let event = makeEvent(day: day, coverPath: "/preview/friday/cover.png")

        let manifest = PythonBridge.buildCoverManifest(event: event, day: .friday, overrideSource: nil)

        let dayInfo = manifest?["day_info"] as? [String: Any]
        let clipsPlan = dayInfo?["clips_plan"] as? [String: Any]
        XCTAssertNotNil(clipsPlan, "the persisted fridayClipPlan must reach generate_cover.py so it never re-cuts")
        let selections = clipsPlan?["selections"] as? [[String: Any]]
        XCTAssertEqual(selections?.first?["clip_path"] as? String, "/clips/a.mov")
        XCTAssertEqual(selections?.first?["transition"] as? String, "crossfade")
    }

    func testOverrideSourceIsCarriedWhenGiven() {
        var day = PostingDay(day: .thursday)
        day.photoPaths = [URL(fileURLWithPath: "/photos/a.jpg")]
        let event = makeEvent(day: day)

        let manifest = PythonBridge.buildCoverManifest(
            event: event, day: .thursday, overrideSource: URL(fileURLWithPath: "/photos/chosen.jpg")
        )

        XCTAssertEqual(manifest?["override_source"] as? String, "/photos/chosen.jpg")
    }

    // MARK: - parseCoverRegenerationOutput

    func testParsesCoverPathAndPick() {
        let json: [String: Any] = [
            "cover": "/preview/thursday/cover.png",
            "cover_pick": ["source_path": "/photos/b.jpg", "rationale": "sharp soloist"],
        ]

        let result = PythonBridge.parseCoverRegenerationOutput(json)

        XCTAssertEqual(result?.coverPath, "/preview/thursday/cover.png")
        XCTAssertEqual(result?.coverPick?.sourcePath, "/photos/b.jpg")
        XCTAssertEqual(result?.coverPick?.rationale, "sharp soloist")
    }

    func testParsesCoverPathWithNoPickForOverrideMode() {
        let json: [String: Any] = ["cover": "/preview/thursday/cover.png"]

        let result = PythonBridge.parseCoverRegenerationOutput(json)

        XCTAssertEqual(result?.coverPath, "/preview/thursday/cover.png")
        XCTAssertNil(result?.coverPick)
    }

    func testReturnsNilWhenCoverKeyMissing() {
        let json: [String: Any] = ["cover_pick": ["source_path": "/x.jpg", "rationale": "x"]]

        XCTAssertNil(PythonBridge.parseCoverRegenerationOutput(json))
    }
}
