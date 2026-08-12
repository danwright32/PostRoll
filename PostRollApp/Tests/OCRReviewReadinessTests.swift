import XCTest

/// #396: whether the extracted program is good enough to build a week on, and
/// what the screen says about it.
final class OCRReviewReadinessTests: XCTestCase {

    func testGoodDataHasNothingToSay() {
        XCTAssertNil(OCRReviewReadiness.detectedIssues(performerCount: 12, pieceCount: 6))
    }

    func testEachMissingThingIsNamedSeparately() throws {
        let onlyPerformers = try XCTUnwrap(
            OCRReviewReadiness.detectedIssues(performerCount: 0, pieceCount: 6))
        XCTAssertEqual(onlyPerformers.count, 1)
        XCTAssertTrue(onlyPerformers[0].contains("performers"))

        let both = try XCTUnwrap(
            OCRReviewReadiness.detectedIssues(performerCount: 0, pieceCount: 0))
        XCTAssertEqual(both.count, 2, "two different gaps are two different sentences")
    }

    // MARK: - The button

    /// The three states mean three different things, and the label is the only
    /// thing on screen that tells them apart.
    func testTheLabelSaysWhichOfTheThreeStatesThisIs() {
        XCTAssertEqual(
            OCRReviewReadiness.confirmLabel(unresolvedFlagCount: 0, hasDetectedIssues: false),
            "Looks Good")
        XCTAssertEqual(
            OCRReviewReadiness.confirmLabel(unresolvedFlagCount: 0, hasDetectedIssues: true),
            "Continue Anyway")
        XCTAssertEqual(
            OCRReviewReadiness.confirmLabel(unresolvedFlagCount: 3, hasDetectedIssues: true),
            "Resolve 3 issues")
        XCTAssertEqual(
            OCRReviewReadiness.confirmLabel(unresolvedFlagCount: 1, hasDetectedIssues: false),
            "Resolve 1 issue",
            "one issue must not read as issues")
    }

    /// The failure this prevents: a greyed out button with nothing beside it
    /// saying why, which leaves Dan with a dead control (L109).
    func testABlockedButtonAlwaysCarriesAReason() {
        let help = OCRReviewReadiness.confirmHelp(unresolvedFlagCount: 2,
                                                  hasDetectedIssues: false)
        XCTAssertFalse(help.isEmpty, "the button is disabled here, so it has to say why")
        XCTAssertTrue(help.contains("flagged issue"))
    }

    func testAnUnblockedButtonWithGoodDataSaysNothingExtra() {
        XCTAssertEqual(
            OCRReviewReadiness.confirmHelp(unresolvedFlagCount: 0, hasDetectedIssues: false),
            "", "nothing to warn about, so no warning")
    }

    func testGoingAheadWithThinDataSaysWhatThatCosts() {
        let help = OCRReviewReadiness.confirmHelp(unresolvedFlagCount: 0,
                                                  hasDetectedIssues: true)
        XCTAssertTrue(help.contains("generic captions"))
    }

    /// Flags win over thin data: there is something to do first, so the message
    /// about it has to be the one shown.
    func testUnresolvedFlagsOutrankThinData() {
        XCTAssertTrue(
            OCRReviewReadiness.confirmHelp(unresolvedFlagCount: 1, hasDetectedIssues: true)
                .contains("flagged issue"))
    }

    // MARK: - Notices

    func testTheSkippedSpellCheckNoticeCarriesTheReasonAndWhatToDo() {
        let message = OCRReviewReadiness.visionSkippedMessage(
            "The program pages were too large to read.")

        XCTAssertTrue(message.contains("not spell-checked"))
        XCTAssertTrue(message.contains("too large to read"), "the reason survives")
        XCTAssertTrue(message.contains("Check performer names"), "and so does the instruction")
    }

    func testTheFlagFailureNoticeSaysWhatDidAndDidNotHappen() {
        let message = OCRReviewReadiness.flagErrorMessage("connection reset by peer")

        XCTAssertTrue(message.contains("connection reset by peer"))
        XCTAssertTrue(message.contains("data was extracted"),
                      "the extraction worked, and saying so stops this reading as total loss")
        XCTAssertTrue(message.contains("manually"))
    }
}
