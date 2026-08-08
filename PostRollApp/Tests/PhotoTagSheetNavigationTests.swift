import XCTest

/// The tagging sheet shows one photo large and walks the day's carousel with
/// previous/next (#171 follow-up: 80pt thumbnails are too small to tell who
/// is actually in the frame). The stepping is pure logic so the ends, a
/// single-photo day, and an index left pointing past the end can all be
/// tested without driving the UI.
final class PhotoTagSheetNavigationTests: XCTestCase {

    func testStepsForwardAndBackwardThroughTheDay() {
        XCTAssertEqual(PhotoTagSheetNavigation.next(from: 0, count: 10), 1)
        XCTAssertEqual(PhotoTagSheetNavigation.previous(from: 5, count: 10), 4)
    }

    func testStopsAtTheEndsRatherThanWrappingAround() {
        XCTAssertEqual(PhotoTagSheetNavigation.next(from: 9, count: 10), 9,
                       "past the last photo there is nowhere to go, and wrapping would hide that")
        XCTAssertEqual(PhotoTagSheetNavigation.previous(from: 0, count: 10), 0)
        XCTAssertFalse(PhotoTagSheetNavigation.canGoNext(from: 9, count: 10))
        XCTAssertFalse(PhotoTagSheetNavigation.canGoPrevious(from: 0, count: 10))
        XCTAssertTrue(PhotoTagSheetNavigation.canGoNext(from: 8, count: 10))
        XCTAssertTrue(PhotoTagSheetNavigation.canGoPrevious(from: 1, count: 10))
    }

    func testASinglePhotoDayCanGoNowhere() {
        XCTAssertFalse(PhotoTagSheetNavigation.canGoNext(from: 0, count: 1))
        XCTAssertFalse(PhotoTagSheetNavigation.canGoPrevious(from: 0, count: 1))
        XCTAssertEqual(PhotoTagSheetNavigation.label(index: 0, count: 1), "Photo 1 of 1")
    }

    func testTheLabelCountsFromOneNotZero() {
        XCTAssertEqual(PhotoTagSheetNavigation.label(index: 0, count: 10), "Photo 1 of 10")
        XCTAssertEqual(PhotoTagSheetNavigation.label(index: 9, count: 10), "Photo 10 of 10")
    }

    // MARK: - Degenerate input

    func testAnIndexPastTheEndIsPulledBackInsteadOfCrashing() {
        XCTAssertEqual(PhotoTagSheetNavigation.clamped(index: 14, count: 10), 9,
                       "a stale index must land on a real photo, never off the end")
        XCTAssertEqual(PhotoTagSheetNavigation.clamped(index: -3, count: 10), 0)
        XCTAssertEqual(PhotoTagSheetNavigation.clamped(index: 4, count: 10), 4)
    }

    func testNoPhotosAtAllIsHandledWithoutGoingNegative() {
        XCTAssertEqual(PhotoTagSheetNavigation.clamped(index: 3, count: 0), 0)
        XCTAssertFalse(PhotoTagSheetNavigation.canGoNext(from: 0, count: 0))
        XCTAssertFalse(PhotoTagSheetNavigation.canGoPrevious(from: 0, count: 0))
        XCTAssertEqual(PhotoTagSheetNavigation.next(from: 0, count: 0), 0)
        XCTAssertEqual(PhotoTagSheetNavigation.previous(from: 0, count: 0), 0)
    }
}
