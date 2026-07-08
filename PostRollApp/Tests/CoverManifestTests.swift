import XCTest

/// Phase 2 (#140): the sticky cover-image gate (Phase 1's select_cover_photo.py)
/// skips its Claude call when the outgoing manifest already carries a
/// cover_source for the day. Both manifest builders (buildMediaManifest used
/// by generate_media.py, and buildManifest used by generate_week.py) must
/// carry the day's persisted coverOverride ?? coverPick?.sourcePath, mirroring
/// the clips/clips_plan wiring FridayManifestClipsTests.swift already pins.
final class CoverManifestTests: XCTestCase {

    private func makeEvent(thursday: PostingDay? = nil, friday: PostingDay? = nil) -> Event {
        var event = Event(name: "Test Show", org: "Org", venue: "Hall", date: Date(timeIntervalSince1970: 0), shootType: .fullShow)
        event.ocrResult = OCRResult(performers: [])
        if let thursday { event.days["thursday"] = thursday }
        if let friday { event.days["friday"] = friday }
        return event
    }

    private func dayWithPhoto() -> PostingDay {
        var day = PostingDay(day: .thursday)
        day.photoPaths = [URL(fileURLWithPath: "/photos/a.jpg")]
        return day
    }

    // MARK: - buildMediaManifest (generate_media.py / preview generation)

    func testBuildMediaManifestSendsCoverPickSourcePathWhenNoOverride() async {
        var day = dayWithPhoto()
        day.coverPick = CoverPick(sourcePath: "/photos/picked.jpg", rationale: "sharp soloist")
        let event = makeEvent(thursday: day)

        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        let thursday = (manifest["days"] as? [String: Any])?["thursday"] as? [String: Any]
        XCTAssertEqual(thursday?["cover_source"] as? String, "/photos/picked.jpg")
    }

    func testBuildMediaManifestOverridePreferredOverPick() async {
        var day = dayWithPhoto()
        day.coverPick = CoverPick(sourcePath: "/photos/picked.jpg", rationale: "sharp soloist")
        day.coverOverride = "/photos/user_choice.jpg"
        let event = makeEvent(thursday: day)

        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        let thursday = (manifest["days"] as? [String: Any])?["thursday"] as? [String: Any]
        XCTAssertEqual(thursday?["cover_source"] as? String, "/photos/user_choice.jpg",
                       "a manual override must win over the AI pick, same nil-means-AI semantics as collageCellOverride")
    }

    func testBuildMediaManifestOmitsCoverSourceWhenNeitherIsSet() async {
        let event = makeEvent(thursday: dayWithPhoto())

        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        let thursday = (manifest["days"] as? [String: Any])?["thursday"] as? [String: Any]
        XCTAssertNil(thursday?["cover_source"], "no persisted pick yet: cover_source must be absent, not an empty string")
    }

    func testBuildMediaManifestCarriesCoverSourceForFridayToo() async {
        var day = PostingDay(day: .friday)
        day.clipPaths = [URL(fileURLWithPath: "/clips/a.mov")]
        day.coverPick = CoverPick(sourcePath: "/tmp/cover_frame.jpg", rationale: "strong wide shot")
        let event = makeEvent(friday: day)

        let manifest = await PythonBridge.shared.buildMediaManifest(event: event)

        let friday = (manifest["days"] as? [String: Any])?["friday"] as? [String: Any]
        XCTAssertEqual(friday?["cover_source"] as? String, "/tmp/cover_frame.jpg")
    }

    // MARK: - buildManifest (generate_week.py / caption pipeline)

    func testBuildManifestCarriesCoverSource() async throws {
        var day = dayWithPhoto()
        day.coverOverride = "/photos/user_choice.jpg"
        let event = makeEvent(thursday: day)

        let manifest = try await PythonBridge.shared.buildManifest(event: event)

        let thursday = (manifest["days"] as? [String: Any])?["thursday"] as? [String: Any]
        XCTAssertEqual(thursday?["cover_source"] as? String, "/photos/user_choice.jpg")
    }
}
