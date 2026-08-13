import XCTest

/// #460, #462 and #463: three surfaces that told Dan something they had not
/// checked, or gave him no way out of the state he was in.
final class HonestStateTests: XCTestCase {

    // MARK: - #463, the Posts list's empty state

    func testAnEmptySegmentIsNotReportedAsASearchMiss() {
        // The Stories segment holding nothing is not a failed search, and the
        // old sentence rendered it as `No posts match ""`, naming a control Dan
        // never touched (L11).
        let message = InsightsPostsEmpty.message(searchText: "", filter: "Stories")
        XCTAssertFalse(message.contains("match"), message)
        XCTAssertTrue(message.contains("stories"), message)
    }

    func testASearchMissNamesWhatWasSearchedFor() {
        let message = InsightsPostsEmpty.message(searchText: "decoda", filter: "All")
        XCTAssertTrue(message.contains("decoda"), message)
    }

    func testAWhitespaceOnlyQueryIsNotASearch() {
        // Typing a space is not a query, and quoting it back reads as a bug.
        let message = InsightsPostsEmpty.message(searchText: "   ", filter: "Feed")
        XCTAssertFalse(message.contains("match"), message)
    }

    // MARK: - #462, brand voice writes

    func testAFailedNoteSaysTheTextIsStillThere() {
        // The whole risk: the only copy of what Dan typed is in the sheet that
        // was about to close (L12).
        let message = BrandVoiceSaveText.failed("Permission denied.")
        XCTAssertTrue(message.contains("Permission denied."), message)
        XCTAssertTrue(message.contains("nothing is lost"), message)
    }

    func testANoteFailureDoesNotClaimTheRevisionFailed() {
        // Two independent outcomes, and reporting them as one would tell him his
        // revision had not happened when it had (L53).
        let message = BrandVoiceSaveText.revisionLandedButNoteDidNot("Disk full.")
        XCTAssertTrue(message.contains("revision was applied"), message)
        XCTAssertTrue(message.contains("Disk full."), message)
    }

    func testNeitherMessageDoublesTheFullStopOnASystemError() {
        // A Cocoa error already ends in one, and the first render of a screen is
        // what shows the double stop (#405).
        for message in [BrandVoiceSaveText.failed("It already exists."),
                        BrandVoiceSaveText.revisionLandedButNoteDidNot("It already exists.")] {
            XCTAssertFalse(message.contains(".."), message)
        }
    }

    // MARK: - #460, long runs

    func testLocalWorkStallsWellBeforeAClaudeCallWould() {
        // A CSV parse held to the Claude threshold would still look healthy ten
        // minutes after it hung.
        XCTAssertLessThan(LongRunState.localWorkSilenceThreshold,
                          LongRunState.defaultSilenceThreshold)
    }

    func testALocalRunThatGoesQuietConvertsToAStalledState() {
        let started = Date(timeIntervalSince1970: 0)
        let status = LongRunState.status(
            startedAt: started, step: nil,
            now: started.addingTimeInterval(LongRunState.localWorkSilenceThreshold + 1),
            silenceThreshold: LongRunState.localWorkSilenceThreshold)

        guard case .stalled = status else {
            return XCTFail("a local run that has said nothing reads as \(status)")
        }
    }

    func testALocalRunInProgressReportsHowLongItHasBeenGoing() {
        let started = Date(timeIntervalSince1970: 0)
        let status = LongRunState.status(
            startedAt: started, step: nil, now: started.addingTimeInterval(9),
            silenceThreshold: LongRunState.localWorkSilenceThreshold)

        // Working, still alive, and failed have to be visibly distinct, which
        // starts with the elapsed time being a real number rather than a
        // spinner that looks the same at nine seconds and at nine minutes.
        XCTAssertEqual(status, .working(elapsedSeconds: 9, step: nil))
    }
}
