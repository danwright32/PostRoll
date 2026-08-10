import XCTest

/// Coverage for the posting preset spec (`PostingPreset`) that decides each
/// day's shape, and the persistence in `PostingPresetStore`. The mapping here
/// must mirror `postroll/posting_preset.py` exactly.
final class PostingPresetTests: XCTestCase {

    func testBalancedMakesSunMonWedCollageCarousels() {
        for day in [DayName.sunday, .monday, .wednesday] {
            let fmt = PostingPreset.balanced.format(for: day)
            XCTAssertEqual(fmt?.format, .collageCarousel, "\(day) should be a carousel under balanced")
            XCTAssertEqual(fmt?.count, 4, "\(day) should use 4 photos under balanced")
            XCTAssertTrue(PostingPreset.balanced.isCollageCarousel(day))
        }
    }

    func testClassicMatchesOriginalOneOneTen() {
        XCTAssertEqual(PostingPreset.classic.format(for: .sunday)?.format, .single)
        XCTAssertEqual(PostingPreset.classic.format(for: .sunday)?.count, 1)
        XCTAssertEqual(PostingPreset.classic.format(for: .monday)?.format, .single)
        XCTAssertEqual(PostingPreset.classic.format(for: .wednesday)?.format, .collageCarousel)
        XCTAssertEqual(PostingPreset.classic.format(for: .wednesday)?.count, 10)
        XCTAssertFalse(PostingPreset.classic.isCollageCarousel(.sunday))
    }

    func testNonGovernedDaysReturnNilInEveryPreset() {
        for preset in PostingPreset.allCases {
            for day in [DayName.tuesday, .thursday, .friday] {
                XCTAssertNil(preset.format(for: day), "\(day) is not governed by \(preset)")
            }
        }
    }

    func testRawValuesMatchPythonContract() {
        // These strings travel in the manifest to Python — they must not drift.
        XCTAssertEqual(PostingPreset.balanced.rawValue, "balanced")
        XCTAssertEqual(PostingPreset.classic.rawValue, "classic")
    }

    // MARK: - Collage photo selection floor (#63)

    func testCollageTargetMatchesPreset() {
        XCTAssertEqual(CollagePhotoSelection.target(preset: .balanced, day: .sunday), 4)
        XCTAssertEqual(CollagePhotoSelection.target(preset: .classic, day: .wednesday), 10)
    }

    func testCollageSelectionAllowsFewerThanTarget() {
        // A balanced day targets 4, but picking 3 must be allowed — the
        // generator adapts. Only below the 2-photo floor is rejected.
        XCTAssertNil(CollagePhotoSelection.validationError(selectedCount: 3, dayDisplayName: "Sunday"))
        XCTAssertNil(CollagePhotoSelection.validationError(selectedCount: 2, dayDisplayName: "Sunday"))
    }

    func testCollageSelectionRejectsBelowFloor() {
        let message = CollagePhotoSelection.validationError(selectedCount: 1, dayDisplayName: "Sunday")
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("at least 2") ?? false)
        XCTAssertTrue(message?.contains("Sunday") ?? false)
    }

    // MARK: - Days a layout switch rebuilds (#71)

    func testAffectedDaysAreGovernedDaysWithPhotos() {
        var event = Event(name: "Show", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
        var sun = PostingDay(day: .sunday); sun.photoPaths = [URL(fileURLWithPath: "/a.jpg")]
        var wed = PostingDay(day: .wednesday); wed.photoPaths = [URL(fileURLWithPath: "/b.jpg")]
        let mon = PostingDay(day: .monday) // no photos
        var tue = PostingDay(day: .tuesday); tue.photoPaths = [URL(fileURLWithPath: "/c.jpg")]
        event.days = [
            DayName.sunday.rawValue: sun,
            DayName.monday.rawValue: mon,
            DayName.wednesday.rawValue: wed,
            DayName.tuesday.rawValue: tue,
        ]
        let affected = PostingPreset.balanced.affectedDays(in: event)
        XCTAssertEqual(Set(affected), [.sunday, .wednesday],
                       "only preset-governed days that actually have photos rebuild")
        XCTAssertFalse(affected.contains(.monday), "a governed day with no photos is skipped")
        XCTAssertFalse(affected.contains(.tuesday), "Tuesday isn't governed by the preset")
    }

    // MARK: - Per-event override (#66)

    private func makeEvent() -> Event {
        Event(name: "Show", org: "Org", venue: "Hall",
              date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
    }

    /// A scratch defaults store holding this preset, handed to the code under
    /// test.
    ///
    /// The real preference is never read or written. Saving and restoring it
    /// around the test was careful but not safe: a crash between the two left
    /// Dan's actual posting layout changed, and two suites running at once
    /// clobbered each other (#116).
    private func scratchDefaults(_ preset: PostingPreset) -> UserDefaults {
        let suite = "postroll.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(preset.rawValue, forKey: PostingPreset.storageKey)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func withGlobalPreset(_ preset: PostingPreset,
                                  _ body: (UserDefaults) -> Void) {
        body(scratchDefaults(preset))
    }

    func testEffectivePresetUsesOverrideWhenSet() {
        var event = makeEvent()
        event.postingPresetOverride = .classic
        // The override wins regardless of the global default.
        withGlobalPreset(.balanced) { defaults in
            XCTAssertEqual(event.effectivePostingPreset(in: defaults), .classic)
        }
    }

    func testEffectivePresetFallsBackToGlobalWhenNoOverride() {
        var event = makeEvent()
        event.postingPresetOverride = nil
        withGlobalPreset(.classic) { defaults in
            XCTAssertEqual(event.effectivePostingPreset(in: defaults), .classic)
        }
        withGlobalPreset(.balanced) { defaults in
            XCTAssertEqual(event.effectivePostingPreset(in: defaults), .balanced)
        }
    }

    func testOverrideSurvivesCodableRoundTrip() throws {
        var event = makeEvent()
        event.postingPresetOverride = .classic
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        XCTAssertEqual(decoded.postingPresetOverride, .classic)
    }

    func testMissingOverrideDecodesAsNil() throws {
        // An event saved before this field existed must decode with no override.
        var event = makeEvent()
        event.postingPresetOverride = nil
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        XCTAssertNil(decoded.postingPresetOverride)
    }

    @MainActor
    func testStoreDefaultsToBalancedAndPersists() {
        // Its own scratch suite, so the real preference is neither read nor
        // written and two suites running at once cannot collide (#116).
        let suite = "postroll.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }

        XCTAssertEqual(PostingPresetStore(defaults: defaults).selected, .balanced,
                       "a fresh store defaults to balanced")

        let store = PostingPresetStore(defaults: defaults)
        store.selected = .classic
        store.save()
        XCTAssertEqual(PostingPreset.current(in: defaults), .classic)
        XCTAssertEqual(PostingPresetStore(defaults: defaults).selected, .classic,
                       "a new store reads back the persisted preset")
    }
}

/// #107: the presets are stated once in `tests/fixtures/posting_presets.json`,
/// and both implementations assert against that same file.
///
/// Before this, `postroll/posting_preset.py` was the declared source of truth
/// with no direct tests, while only this Swift mirror was pinned. The source
/// could therefore change and only the copy would complain, which is backwards.
/// Sharing the fixture means neither side can drift without somebody editing
/// the fixture deliberately.
final class PostingPresetSharedFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let preset: String
            let day: String
            let format: String?
            let count: Int?
        }
        let default_preset: String
        let cases: [Case]
        let unknown_preset_falls_back_to_default: [Case]
    }

    /// Located from this file, not a bundle resource: the test target has no
    /// resource phase, and a copied fixture would be a second copy able to
    /// drift from the one Python reads, which is the whole thing being fixed.
    private func loadFixture() throws -> Fixture {
        return try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/posting_presets.json"))
    }

    private func day(named name: String) -> DayName? {
        DayName.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
    }

    /// The wire strings Python uses. Mapped here rather than added to the enum
    /// as a rawValue: DayFormat is never serialised, so a rawValue would exist
    /// only for the test and could then be wrong without anything noticing.
    private func wireName(_ format: DayFormat) -> String {
        switch format {
        case .single:          return "single"
        case .collageCarousel: return "collage_carousel"
        }
    }

    private func preset(named name: String) -> PostingPreset {
        PostingPreset(rawValue: name) ?? .balanced
    }

    func testTheFixtureIsReadable() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.cases.isEmpty, "an empty fixture would assert nothing")
    }

    func testTheDefaultPresetMatchesTheFixture() throws {
        XCTAssertEqual(PostingPreset.balanced.rawValue, try loadFixture().default_preset)
    }

    func testEveryFixtureCaseMatchesTheSwiftMirror() throws {
        let fixture = try loadFixture()
        for c in fixture.cases {
            guard let day = day(named: c.day) else {
                return XCTFail("fixture names a day Swift does not have: \(c.day)")
            }
            let result = preset(named: c.preset).format(for: day)
            if let expectedFormat = c.format, let expectedCount = c.count {
                XCTAssertEqual(result.map { wireName($0.format) }, expectedFormat,
                               "\(c.preset)/\(c.day)")
                XCTAssertEqual(result?.count, expectedCount, "\(c.preset)/\(c.day)")
            } else {
                XCTAssertNil(result,
                             "\(c.day) is not governed by the preset, so it must be nil")
            }
        }
    }

    func testIsCollageCarouselAgreesWithTheFixture() throws {
        for c in try loadFixture().cases {
            guard let day = day(named: c.day) else { continue }
            XCTAssertEqual(preset(named: c.preset).isCollageCarousel(day),
                           c.format == "collage_carousel",
                           "\(c.preset)/\(c.day)")
        }
    }

    func testAnUnknownPresetFallsBackTheSameWayPythonDoes() throws {
        for c in try loadFixture().unknown_preset_falls_back_to_default {
            guard let day = day(named: c.day) else { continue }
            let result = preset(named: c.preset).format(for: day)
            XCTAssertEqual(result.map { wireName($0.format) }, c.format, c.preset)
            XCTAssertEqual(result?.count, c.count, c.preset)
        }
    }
}

/// #195: the upload page gated the collage on a hardcoded 10, a literal left
/// over from the Classic preset. Under the default Balanced preset a Wednesday
/// with its full 4 photos was told it needed 6 more, and the reroll button
/// behind the same check was unreachable for the entire default preset.
final class CollageGeneratableTests: XCTestCase {

    func testTheDefaultPresetsFullDayCanGenerate() {
        // Balanced gives Wednesday 4 photos. That is a complete day, not a
        // shortfall, and it is the case that was broken.
        let target = CollagePhotoSelection.target(preset: .balanced, day: .wednesday)
        XCTAssertEqual(target, 4)
        XCTAssertTrue(CollagePhotoSelection.canGenerate(photoCount: target))
        XCTAssertNil(CollagePhotoSelection.shortfallMessage(photoCount: target))
    }

    func testBelowTheTargetButAboveTheFloorStillGenerates() {
        // The generator adapts below the target, so 3 of 4 is allowed. Gating
        // on the target rather than the floor is the same mistake in miniature.
        XCTAssertTrue(CollagePhotoSelection.canGenerate(photoCount: 3))
        XCTAssertNil(CollagePhotoSelection.shortfallMessage(photoCount: 3))
    }

    func testTheFloorIsTwo() {
        XCTAssertTrue(CollagePhotoSelection.canGenerate(photoCount: 2))
        XCTAssertFalse(CollagePhotoSelection.canGenerate(photoCount: 1))
        XCTAssertFalse(CollagePhotoSelection.canGenerate(photoCount: 0))
    }

    func testTheShortfallCountsAgainstTheFloorNotTheTarget() {
        // Asking for photos that are not actually required is what made the
        // old message wrong.
        let message = CollagePhotoSelection.shortfallMessage(photoCount: 1)
        XCTAssertEqual(message, "Need at least 2 photos to generate the collage. 1 more required.")
        XCTAssertFalse(message?.contains("10") ?? false)
    }

    func testClassicWednesdayStillTargetsTen() {
        // The target is unchanged; only the GATE moved off it.
        XCTAssertEqual(CollagePhotoSelection.target(preset: .classic, day: .wednesday), 10)
    }
}
