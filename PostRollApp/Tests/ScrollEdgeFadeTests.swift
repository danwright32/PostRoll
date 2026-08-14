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
        XCTAssertTrue(ScrollEdgeFade.showsTrailingEdge(contentLength: 600,
                                                 viewportLength: 200,
                                                 scrollOffset: 0))
    }

    func testAListThatFitsShowsNothing() {
        XCTAssertFalse(ScrollEdgeFade.showsTrailingEdge(contentLength: 120,
                                                  viewportLength: 200,
                                                  scrollOffset: 0))
    }

    func testAListThatExactlyFitsShowsNothing() {
        // A permanent fade over nothing is its own kind of lie.
        XCTAssertFalse(ScrollEdgeFade.showsTrailingEdge(contentLength: 200,
                                                  viewportLength: 200,
                                                  scrollOffset: 0))
    }

    func testSubPixelOverflowIsNotTreatedAsMoreContent() {
        XCTAssertFalse(ScrollEdgeFade.showsTrailingEdge(contentLength: 200.4,
                                                  viewportLength: 200,
                                                  scrollOffset: 0))
    }

    func testTheFadeGoesOnceTheEndIsReached() {
        // Scrolled fully: 600 of content, 200 visible, so 400 scrolled.
        XCTAssertFalse(ScrollEdgeFade.showsTrailingEdge(contentLength: 600,
                                                  viewportLength: 200,
                                                  scrollOffset: 400))
    }

    func testTheFadeStaysWhilePartwayDown() {
        XCTAssertTrue(ScrollEdgeFade.showsTrailingEdge(contentLength: 600,
                                                 viewportLength: 200,
                                                 scrollOffset: 100))
    }

    func testOverscrollDoesNotBringTheFadeBack() {
        // Rubber banding can push the offset past the end.
        XCTAssertFalse(ScrollEdgeFade.showsTrailingEdge(contentLength: 600,
                                                  viewportLength: 200,
                                                  scrollOffset: 460))
    }

    func testTheTopFadeAppearsOnlyOnceScrolled() {
        XCTAssertFalse(ScrollEdgeFade.showsLeadingEdge(scrollOffset: 0))
        XCTAssertTrue(ScrollEdgeFade.showsLeadingEdge(scrollOffset: 40))
    }

    func testAZeroHeightViewportIsNotAnOverflow() {
        // Before first layout everything is zero; a fade then would flash.
        XCTAssertFalse(ScrollEdgeFade.showsTrailingEdge(contentLength: 0,
                                                  viewportLength: 0,
                                                  scrollOffset: 0))
    }
}
