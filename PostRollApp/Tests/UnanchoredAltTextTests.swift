import XCTest

/// #1035: what the screen says about a day whose anchors could not be
/// recovered.
final class UnanchoredAltTextTests: XCTestCase {

    func testACarouselWithNoAnchorsSaysTheOrderIsUnverified() {
        let line = AltTextScope.line(day: .wednesday, isCarousel: true,
                                     photos: 6, altTexts: 4, anchored: false)

        XCTAssertEqual(line?.contains("order is unverified"), true, line ?? "nil")
    }

    func testAnAnchoredCarouselDoesNotCarryTheWarning() {
        // The mark goes on the days that need it. A sentence on every carousel
        // would be read past within a week (L36).
        let line = AltTextScope.line(day: .wednesday, isCarousel: true,
                                     photos: 6, altTexts: 6, anchored: true)

        XCTAssertEqual(line?.contains("unverified"), false, line ?? "nil")
    }

    /// A reel has one description of the whole video and no anchors by design,
    /// so the warning must not appear there: it would name a fault that cannot
    /// exist (L11).
    func testAReelIsNotAccusedOfAnUnverifiedOrder() {
        let line = AltTextScope.line(day: .thursday, isCarousel: false,
                                     photos: 137, altTexts: 1, anchored: false)

        XCTAssertEqual(line?.contains("unverified"), false, line ?? "nil")
    }
}
