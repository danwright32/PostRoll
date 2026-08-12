import XCTest

/// #88: the failure has to outrank the empty state. Showing "no posts imported
/// yet" over a store that could not be read tells Dan to go and import, when
/// his existing import is sitting unreadable in a file beside the store.
final class InsightsDisplayTests: XCTestCase {

    func testAFailedLoadShowsTheFailureNotTheEmptyState() {
        let state = InsightsDisplay.state(recoveryMessage: "could not be read", postCount: 0)
        XCTAssertEqual(state, .failedToLoad("could not be read"))
    }

    func testAGenuinelyEmptyStoreShowsTheEmptyState() {
        XCTAssertEqual(InsightsDisplay.state(recoveryMessage: nil, postCount: 0), .empty)
    }

    func testAStoreWithPostsShowsTheData() {
        XCTAssertEqual(InsightsDisplay.state(recoveryMessage: nil, postCount: 12), .data)
    }

    func testAFailureStillShowsEvenWhenSomePostsLoaded() {
        // A partial read is still a read that went wrong; the count must not
        // be allowed to hide it.
        XCTAssertEqual(InsightsDisplay.state(recoveryMessage: "partial", postCount: 3),
                       .failedToLoad("partial"))
    }

    func testAnEmptyMessageIsNotAFailure() {
        XCTAssertEqual(InsightsDisplay.state(recoveryMessage: "", postCount: 0), .empty)
    }

    func testTheBannerShowsOnlyOnAFailure() {
        XCTAssertTrue(InsightsDisplay.showsRecoveryBanner(recoveryMessage: "x", postCount: 0))
        XCTAssertFalse(InsightsDisplay.showsRecoveryBanner(recoveryMessage: nil, postCount: 0))
        XCTAssertFalse(InsightsDisplay.showsRecoveryBanner(recoveryMessage: nil, postCount: 5))
    }
}
