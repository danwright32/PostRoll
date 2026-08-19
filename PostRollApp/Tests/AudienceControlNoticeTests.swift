import XCTest

/// What a report says about how much of it could not be controlled for
/// audience size (#720).
///
/// Posts whose credited account has no follower band are analysed as
/// uncontrolled observations rather than compared within a tier. That is the
/// right treatment, and #712 made the stored bands visible and correctable.
/// This is the output side: the finished report read exactly the same whether
/// that applied to two posts or two hundred, so a thin report was
/// indistinguishable from one where every comparison was fair.
///
/// Pure, so every case can be stated and asserted without a screen behind it
/// (L151).
final class AudienceControlNoticeTests: XCTestCase {

    private func report(analyzed: Int?, uncontrolled: Int?, uncredited: Int? = 0,
                        orgs: [String] = []) -> InsightReport {
        let empty = InsightFindings(captionPatterns: [], hashtagPatterns: [],
                                    contentTypePatterns: [], timingPatterns: [])
        return InsightReport(
            id: UUID(), generatedAt: Date(),
            dateRangeStart: Date(), dateRangeEnd: Date(),
            postCount: analyzed ?? 0, storyCount: 0, feedCount: analyzed ?? 0,
            summary: "", feedFindings: empty, storyFindings: empty,
            brandVoiceSuggestions: [], caveats: [],
            analyzedCount: analyzed, uncontrolledCount: uncontrolled,
            uncreditedCount: uncredited, uncontrolledOrgs: orgs)
    }

    // MARK: - The three states, which must not look alike

    func testAReportWhereEveryComparisonWasFairSaysSo() throws {
        let notice = try XCTUnwrap(
            AudienceControlNotice.forReport(report(analyzed: 40, uncontrolled: 0)))
        XCTAssertEqual(notice.kind, .allControlled)
        XCTAssertTrue(notice.headline.lowercased().contains("every"),
                      "a fully controlled report says nothing to distinguish it "
                      + "from one nobody measured: \(notice.headline)")
        XCTAssertTrue(notice.accounts.isEmpty)
    }

    func testAThinReportSaysHowManyAndOutOfHowMany() throws {
        // The number on its own is not enough: 12 is most of a 15 post report
        // and a rounding error in a 400 post one, and the whole point is being
        // able to tell those apart.
        let notice = try XCTUnwrap(AudienceControlNotice.forReport(
            report(analyzed: 40, uncontrolled: 12, orgs: ["newchoir"])))
        XCTAssertEqual(notice.kind, .someUncontrolled)
        XCTAssertTrue(notice.headline.contains("12"), notice.headline)
        XCTAssertTrue(notice.headline.contains("40"),
                      "the count has no denominator, so a reader cannot tell "
                      + "whether it is most of the report or a rounding error: "
                      + notice.headline)
    }

    func testAnOlderReportSaysItWasNeverMeasuredRatherThanZero() throws {
        // Zero and "nobody measured" are different facts. A missing measurement
        // rendered as zero is indistinguishable from a report where every
        // comparison was controlled, which is the most reassuring possible
        // reading of the least informative state (L90, L10).
        let notice = try XCTUnwrap(AudienceControlNotice.forReport(
            report(analyzed: nil, uncontrolled: nil, uncredited: nil)))
        XCTAssertEqual(notice.kind, .notMeasured)
        XCTAssertFalse(notice.headline.contains("0"),
                       "an unmeasured report is claiming a number: " + notice.headline)
    }

    // MARK: - Naming what would fix it

    func testTheAccountsToGoAndTagAreNamed() throws {
        let notice = try XCTUnwrap(AudienceControlNotice.forReport(
            report(analyzed: 40, uncontrolled: 5, orgs: ["newchoir", "smallensemble"])))
        XCTAssertEqual(notice.accounts, ["newchoir", "smallensemble"])
        XCTAssertTrue(notice.showsAccountsLink,
                      "the accounts are named and there is no way to reach the "
                      + "screen that sets their bands, so the notice names a "
                      + "problem and no next step (L80, L111)")
    }

    func testAPostWithNoAccountCreditedIsCountedButSendsNobodyAnywhere() throws {
        // A different cause with a different remedy: no band can be set for an
        // account that was never credited, so offering the accounts screen for
        // it would be a control that cannot change the state it is offered for.
        let notice = try XCTUnwrap(AudienceControlNotice.forReport(
            report(analyzed: 40, uncontrolled: 3, uncredited: 3, orgs: [])))
        XCTAssertEqual(notice.kind, .someUncontrolled)
        XCTAssertTrue(notice.accounts.isEmpty)
        XCTAssertFalse(notice.showsAccountsLink)
        let detail = try XCTUnwrap(notice.detail)
        XCTAssertTrue(detail.lowercased().contains("no account"),
                      "the reader is not told why these cannot be fixed by "
                      + "tagging: " + detail)
    }

    func testBothCausesTogetherAreBothExplained() throws {
        let notice = try XCTUnwrap(AudienceControlNotice.forReport(
            report(analyzed: 40, uncontrolled: 8, uncredited: 3, orgs: ["newchoir"])))
        let detail = try XCTUnwrap(notice.detail)
        XCTAssertTrue(detail.contains("3"), detail)
        XCTAssertTrue(notice.showsAccountsLink)
        XCTAssertEqual(notice.accounts, ["newchoir"])
    }

    // MARK: - What it may claim

    func testTheHeadlineNeverClaimsMoreUncontrolledThanWereAnalysed() throws {
        // A count larger than the population it is out of is a number nobody
        // can act on, and it would read as a bug in the report rather than in
        // whatever produced it.
        let notice = try XCTUnwrap(AudienceControlNotice.forReport(
            report(analyzed: 5, uncontrolled: 9)))
        XCTAssertEqual(notice.kind, .notMeasured,
                       "a measurement that cannot be true was shown as though "
                       + "it were: " + notice.headline)
    }

    func testAReportOfNothingIsNotDescribedAsFullyControlled() throws {
        // Zero of zero posts controlled is true and useless, and drawing it as
        // a tick says the report is sound when there is no report.
        XCTAssertNil(AudienceControlNotice.forReport(
            report(analyzed: 0, uncontrolled: 0)))
    }
}
