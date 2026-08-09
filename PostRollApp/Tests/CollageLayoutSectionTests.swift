import XCTest

/// #195: the collage section on the upload page.
///
/// Three separate defects, all from one assumption that Wednesday is the only
/// collage day and always carries ten photos:
///
/// 1. The reorder hint counted against a hardcoded 10, so under the default
///    Balanced preset it stayed silent between 5 and 10 photos, exactly when it
///    should have been saying only the first 4 are used.
/// 2. "New layout" was offered whenever the collage could render, including at
///    2 and 3 photos where only one arrangement exists, so pressing it redrew
///    the identical collage. A control that visibly does nothing reads as
///    broken (#182, #49).
/// 3. Sunday and Monday are collage days under Balanced and had no collage
///    section at all, so two of the three collage days offered no count
///    guidance, no crop hint and no reroll.
final class CollageLayoutSectionTests: XCTestCase {

    // MARK: - The photo count comes from the preset, not a literal

    func testBalancedWednesdayTargetsFourNotTen() {
        XCTAssertEqual(CollagePhotoSelection.target(preset: .balanced, day: .wednesday), 4)
    }

    func testClassicWednesdayStillTargetsTen() {
        XCTAssertEqual(CollagePhotoSelection.target(preset: .classic, day: .wednesday), 10)
    }

    func testBalancedSundayAndMondayAreCollageDaysToo() {
        XCTAssertTrue(PostingPreset.balanced.isCollageCarousel(.sunday))
        XCTAssertTrue(PostingPreset.balanced.isCollageCarousel(.monday))
        XCTAssertTrue(PostingPreset.balanced.isCollageCarousel(.wednesday))
    }

    func testClassicSundayAndMondayAreSinglePhotoDays() {
        XCTAssertFalse(PostingPreset.classic.isCollageCarousel(.sunday))
        XCTAssertFalse(PostingPreset.classic.isCollageCarousel(.monday))
        XCTAssertTrue(PostingPreset.classic.isCollageCarousel(.wednesday))
    }

    // MARK: - The reorder hint

    func testTheHintFiresOnceMorePhotosThanTheTargetAreAssigned() {
        // Balanced Wednesday: 7 photos against a target of 4. The old literal
        // stayed silent here, which is the reported case.
        let note = CollagePhotoSelection.extraPhotosNote(
            photoCount: 7, preset: .balanced, day: .wednesday)

        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("first 4"), "got: \(note ?? "nil")")
        XCTAssertTrue(note!.contains("7"), "the note must say how many are assigned")
    }

    func testTheHintIsSilentAtExactlyTheTarget() {
        XCTAssertNil(CollagePhotoSelection.extraPhotosNote(
            photoCount: 4, preset: .balanced, day: .wednesday))
    }

    func testTheHintIsSilentBelowTheTarget() {
        XCTAssertNil(CollagePhotoSelection.extraPhotosNote(
            photoCount: 3, preset: .balanced, day: .wednesday))
    }

    func testTheHintCountsAgainstClassicsTargetUnderClassic() {
        XCTAssertNil(CollagePhotoSelection.extraPhotosNote(
            photoCount: 7, preset: .classic, day: .wednesday))
        XCTAssertNotNil(CollagePhotoSelection.extraPhotosNote(
            photoCount: 12, preset: .classic, day: .wednesday))
    }

    func testANonCollageDayNeverGetsTheHint() {
        XCTAssertNil(CollagePhotoSelection.extraPhotosNote(
            photoCount: 40, preset: .balanced, day: .thursday))
    }

    // MARK: - "New layout" only when there is another layout

    func testNoRerollAtTwoOrThreePhotos() {
        // Measured: exactly one arrangement exists, so the button would reseed
        // and redraw the same collage.
        XCTAssertFalse(CollagePhotoSelection.offersAlternativeLayouts(photoCount: 2))
        XCTAssertFalse(CollagePhotoSelection.offersAlternativeLayouts(photoCount: 3))
    }

    func testRerollAtFourPhotos() {
        // Four is the Balanced collage count, so this is the weekly case.
        XCTAssertTrue(CollagePhotoSelection.offersAlternativeLayouts(photoCount: 4))
    }

    func testNoRerollBelowTheFloor() {
        XCTAssertFalse(CollagePhotoSelection.offersAlternativeLayouts(photoCount: 1))
        XCTAssertFalse(CollagePhotoSelection.offersAlternativeLayouts(photoCount: 0))
    }

    func testNoRerollWhereNothingFitsTheCropBudget() {
        // Past 10 the generator finds nothing within the crop budget and falls
        // back to one forced layout, so there is nothing to reroll.
        XCTAssertFalse(CollagePhotoSelection.offersAlternativeLayouts(photoCount: 11))
        XCTAssertFalse(CollagePhotoSelection.offersAlternativeLayouts(photoCount: 20))
    }

    /// The Swift rule and the Python generator must not drift, so both read the
    /// one committed fixture rather than each carrying their own copy of the
    /// answer. A change in the split enumeration turns this red.
    func testTheRerollRuleAgreesWithTheGeneratorsOwnCounts() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("tests/fixtures/collage_arrangements.json")

        let data = try Data(contentsOf: fixture)
        let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let counts = try XCTUnwrap(doc?["arrangements_by_photo_count"] as? [String: Int],
                                   "fixture missing arrangements_by_photo_count")
        XCTAssertFalse(counts.isEmpty, "an empty fixture would pass vacuously")

        for (key, count) in counts {
            let n = try XCTUnwrap(Int(key))
            XCTAssertEqual(
                CollagePhotoSelection.offersAlternativeLayouts(photoCount: n),
                count > 1,
                "\(n) photos: generator reports \(count) arrangement(s)")
        }
    }

    // MARK: - #119: the generation error copy

    func testTheGenerationHintNamesTheRealFloorNotTen() {
        // The old copy asked for 10 on a Balanced Wednesday whose target is 4,
        // so it contradicted the same screen's own advice and asked for six
        // photos more than the generator needs.
        let hint = CollagePhotoSelection.generationShortfallHint(day: .wednesday)

        XCTAssertTrue(hint.contains("at least 2"), "got: \(hint)")
        XCTAssertFalse(hint.contains("10"), "the Classic literal is gone: \(hint)")
    }

    func testTheGenerationHintNamesTheDayThatFailed() {
        // It was hardcoded to Wednesday, so a Sunday collage failure under
        // Balanced sent Dan to the wrong day.
        XCTAssertTrue(
            CollagePhotoSelection.generationShortfallHint(day: .sunday).contains("Sunday"))
        XCTAssertTrue(
            CollagePhotoSelection.generationShortfallHint(day: .monday).contains("Monday"))
    }
}
