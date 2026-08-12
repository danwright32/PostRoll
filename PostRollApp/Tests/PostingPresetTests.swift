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
