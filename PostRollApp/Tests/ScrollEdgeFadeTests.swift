import XCTest

/// #190: the tag suggestion list clipped mid-name with nothing to say more
/// names followed. macOS hides scrollbars until a scroll begins, so an
/// overflowing list reads as a complete one, and on a thirty-performer
/// programme most of the cast is unfindable by anyone who does not know to
/// scroll.
///
/// Both halves of L76 are asserted here: it has to appear while content
/// continues, and it has to stop once the end is reached, or the hint stops
/// meaning anything.
final class ScrollEdgeFadeTests: XCTestCase {

    func testAListThatOverflowsShowsTheFade() {
        XCTAssertTrue(ScrollEdgeFade.showsBottom(contentHeight: 600,
                                                 viewportHeight: 200,
                                                 scrollOffset: 0))
    }

    func testAListThatFitsShowsNothing() {
        XCTAssertFalse(ScrollEdgeFade.showsBottom(contentHeight: 120,
                                                  viewportHeight: 200,
                                                  scrollOffset: 0))
    }

    func testAListThatExactlyFitsShowsNothing() {
        // A permanent fade over nothing is its own kind of lie.
        XCTAssertFalse(ScrollEdgeFade.showsBottom(contentHeight: 200,
                                                  viewportHeight: 200,
                                                  scrollOffset: 0))
    }

    func testSubPixelOverflowIsNotTreatedAsMoreContent() {
        XCTAssertFalse(ScrollEdgeFade.showsBottom(contentHeight: 200.4,
                                                  viewportHeight: 200,
                                                  scrollOffset: 0))
    }

    func testTheFadeGoesOnceTheEndIsReached() {
        // Scrolled fully: 600 of content, 200 visible, so 400 scrolled.
        XCTAssertFalse(ScrollEdgeFade.showsBottom(contentHeight: 600,
                                                  viewportHeight: 200,
                                                  scrollOffset: 400))
    }

    func testTheFadeStaysWhilePartwayDown() {
        XCTAssertTrue(ScrollEdgeFade.showsBottom(contentHeight: 600,
                                                 viewportHeight: 200,
                                                 scrollOffset: 100))
    }

    func testOverscrollDoesNotBringTheFadeBack() {
        // Rubber banding can push the offset past the end.
        XCTAssertFalse(ScrollEdgeFade.showsBottom(contentHeight: 600,
                                                  viewportHeight: 200,
                                                  scrollOffset: 460))
    }

    func testTheTopFadeAppearsOnlyOnceScrolled() {
        XCTAssertFalse(ScrollEdgeFade.showsTop(scrollOffset: 0))
        XCTAssertTrue(ScrollEdgeFade.showsTop(scrollOffset: 40))
    }

    func testAZeroHeightViewportIsNotAnOverflow() {
        // Before first layout everything is zero; a fade then would flash.
        XCTAssertFalse(ScrollEdgeFade.showsBottom(contentHeight: 0,
                                                  viewportHeight: 0,
                                                  scrollOffset: 0))
    }
}
