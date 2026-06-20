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

    @MainActor
    func testStoreDefaultsToBalancedAndPersists() {
        let key = PostingPreset.storageKey
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(PostingPresetStore().selected, .balanced,
                       "a fresh store defaults to balanced")

        let store = PostingPresetStore()
        store.selected = .classic
        store.save()
        XCTAssertEqual(PostingPreset.current, .classic)
        XCTAssertEqual(PostingPresetStore().selected, .classic,
                       "a new store reads back the persisted preset")
    }
}
