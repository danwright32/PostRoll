import XCTest

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
