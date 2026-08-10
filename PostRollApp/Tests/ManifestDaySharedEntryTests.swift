import XCTest

/// #138: the two manifests decide what a day IS in one place.
///
/// `buildMediaManifest` feeds generate_media (images and reels) and
/// `buildManifest` feeds generate_week (captions and blog). Each carried its
/// own near-identical copy of the per-day inclusion guard and the fields both
/// pipelines need, kept in step by hand.
///
/// That duplication already caused a real gap in the Friday clip reel plan: the
/// draft updated only the media builder, so the caption pipeline would never
/// have learned clips existed no matter how well the rest of the feature
/// worked. It was caught by a code-level fact-check before anything was
/// written, which is not a process the next feature is guaranteed.
///
/// The guard below is derived from the shared helper rather than from a list
/// written here, so a field added to the shared entry tomorrow is checked in
/// both manifests on the day it lands (L96).
final class ManifestDaySharedEntryTests: XCTestCase {

    /// An event with every per-day input populated, so no shared field is
    /// absent for want of data rather than for want of wiring.
    private func fullyPopulatedEvent() throws -> Event {
        var event = Event(name: "Vocal Colors", org: "DCINY", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_800_000_000),
                          shootType: .fullShow)
        event.ocrResult = OCRResult(performers: [], pieces: [], scenes: [])

        for day in DayName.allCases {
            var pd = PostingDay(day: day)
            pd.photoPaths = [URL(fileURLWithPath: "/p/\(day.rawValue)-1.jpg"),
                             URL(fileURLWithPath: "/p/\(day.rawValue)-2.jpg")]
            pd.rawPhotoPath = URL(fileURLWithPath: "/p/raw.jpg")
            pd.editedPhotoPath = URL(fileURLWithPath: "/p/edit.jpg")
            pd.coverOverride = "/p/cover-\(day.rawValue).jpg"
            pd.clipPaths = [URL(fileURLWithPath: "/p/clip-\(day.rawValue).mov")]
            event.days[day.rawValue] = pd
        }
        return event
    }

    func testEveryFieldTheDaysShareReachesBothPipelines() async throws {
        let event = try fullyPopulatedEvent()
        let media = await PythonBridge.shared.buildMediaManifest(event: event)
        let week = try await PythonBridge.shared.buildManifest(event: event)

        let mediaDays = try XCTUnwrap(media["days"] as? [String: Any])
        let weekDays = try XCTUnwrap(week["days"] as? [String: Any])

        for day in DayName.allCases {
            let pd = try XCTUnwrap(event.days[day.rawValue])
            let shared = ManifestDay.sharedEntry(pd, day: day)
            XCTAssertFalse(shared.isEmpty, "the shared entry produced nothing, so this is vacuous")

            let inMedia = try XCTUnwrap(mediaDays[day.rawValue] as? [String: Any],
                                        "\(day.rawValue) missing from the media manifest")
            let inWeek = try XCTUnwrap(weekDays[day.rawValue] as? [String: Any],
                                       "\(day.rawValue) missing from the week manifest")

            for (key, value) in shared {
                XCTAssertEqual(String(describing: inMedia[key] ?? "absent"),
                               String(describing: value),
                               "\(day.rawValue).\(key) differs in the media manifest")
                XCTAssertEqual(String(describing: inWeek[key] ?? "absent"),
                               String(describing: value),
                               "\(day.rawValue).\(key) differs in the week manifest, "
                               + "which is exactly how the caption pipeline came to "
                               + "not know clips existed")
            }
        }
    }

    func testBothManifestsIncludeAndExcludeTheSameDays() async throws {
        // A day that reaches one pipeline and not the other is either a caption
        // describing assets nobody made, or assets no caption mentions.
        var event = try fullyPopulatedEvent()

        // Nothing at all: excluded by both.
        event.days[DayName.monday.rawValue] = PostingDay(day: .monday)
        // Clips only, no stills: the case that has to survive, since Friday's
        // auto-cut reel needs no photos.
        var friday = PostingDay(day: .friday)
        friday.clipPaths = [URL(fileURLWithPath: "/p/clip.mov")]
        event.days[DayName.friday.rawValue] = friday

        let media = await PythonBridge.shared.buildMediaManifest(event: event)
        let week = try await PythonBridge.shared.buildManifest(event: event)
        let mediaDays = Set((media["days"] as? [String: Any] ?? [:]).keys)
        let weekDays = Set((week["days"] as? [String: Any] ?? [:]).keys)

        XCTAssertEqual(mediaDays, weekDays)
        XCTAssertFalse(mediaDays.contains(DayName.monday.rawValue))
        XCTAssertTrue(mediaDays.contains(DayName.friday.rawValue))
    }

    func testTheInclusionRuleIsOneRule() {
        // Read straight off the helper, so a change to the rule cannot be made
        // in one builder and forgotten in the other.
        XCTAssertFalse(ManifestDay.isIncluded(PostingDay(day: .sunday)))

        var withPhotos = PostingDay(day: .sunday)
        withPhotos.photoPaths = [URL(fileURLWithPath: "/p/a.jpg")]
        XCTAssertTrue(ManifestDay.isIncluded(withPhotos))

        var withClips = PostingDay(day: .friday)
        withClips.clipPaths = [URL(fileURLWithPath: "/p/a.mov")]
        XCTAssertTrue(ManifestDay.isIncluded(withClips))

        var withRawOnly = PostingDay(day: .tuesday)
        withRawOnly.rawPhotoPath = URL(fileURLWithPath: "/p/raw.jpg")
        XCTAssertTrue(ManifestDay.isIncluded(withRawOnly))

        XCTAssertFalse(ManifestDay.isIncluded(nil))
    }

    func testNeitherBuilderCarriesItsOwnCopyOfTheRule() throws {
        // The point of the helper. Derived from the source so a third builder
        // added later is covered too.
        let bridge = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Services/PythonBridge.swift")
        let text = try String(contentsOf: bridge, encoding: .utf8)

        XCTAssertFalse(text.contains("!pd.photoPaths.isEmpty || pd.rawPhotoPath != nil"),
                       "a builder is spelling the inclusion rule out again "
                       + "instead of asking ManifestDay")
    }
}
