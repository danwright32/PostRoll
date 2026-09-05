import XCTest

/// #958: a check that was right and has been acted on can be taken off the
/// panel.
///
/// Dan got a caption check naming a handle that was not on the tag list. The
/// check was right, he deleted the handle, and the panel then went stale and
/// stopped there. Stale says the TEXT moved, not that the finding was dealt
/// with: it reads the same whether he fixed the exact thing the check named or
/// edited an unrelated word, so the panel went on naming a handle that was no
/// longer in the caption. That is the "trains him to ignore the panel" failure
/// the stale wording itself was written to avoid.
final class ClearedFindingsTests: XCTestCase {

    private func finding(_ code: String, _ detail: String) -> QualityFinding {
        QualityFinding(code: code, message: "m", detail: detail)
    }

    // MARK: - What a clearance is keyed on

    func testAClearedFindingLeavesThePanelAndTheRestStay() {
        let found = [finding("foreign_handle", "@mikepacific0"),
                     finding("foreign_handle", "@someoneelse"),
                     finding("missing_credit", "Jenna Robison")]

        let left = FindingsDisplay.remaining(
            findings: found, cleared: ["foreign_handle|@mikepacific0"])

        XCTAssertEqual(left.map(\.detail), ["@someoneelse", "Jenna Robison"])
    }

    /// The same rule against a different quote is a different finding, which is
    /// why the quote is in the key. Keying on the code alone would clear three
    /// checks when Dan judged one.
    func testClearingOneQuoteDoesNotClearItsNeighbourUnderTheSameRule() {
        let found = [finding("foreign_handle", "@one"),
                     finding("foreign_handle", "@two")]

        let left = FindingsDisplay.remaining(findings: found,
                                             cleared: ["foreign_handle|@one"])

        XCTAssertEqual(left.map(\.detail), ["@two"])
    }

    func testAFindingWithNoQuoteIsStillClearable() {
        let found = [finding("stacked_photos", "")]

        XCTAssertTrue(FindingsDisplay.remaining(
            findings: found, cleared: ["stacked_photos|"]).isEmpty)
    }

    // MARK: - What it does to the panel

    func testAPanelWithEveryCheckClearedSaysNothingAtAll() {
        var caption = DayCaption()
        caption.applyFindings([finding("foreign_handle", "@mikepacific0")],
                              checkedCaption: "the caption")

        caption.clearFinding("foreign_handle|@mikepacific0")

        XCTAssertTrue(caption.openFindings.isEmpty)
        XCTAssertNil(caption.findingsSummary,
                     "the panel stays up over nothing to act on")
    }

    func testTheHeadingCountsWhatIsLeftRatherThanWhatWasFound() {
        var blog = BlogOutput()
        // The body matches what the checks ran on, or the heading is the stale
        // one and this would be asserting about a different sentence.
        blog.body = "the body"
        blog.applyFindings([finding("a", "one"), finding("b", "two")],
                           checkedBody: "the body")

        blog.clearFinding("a|one")

        XCTAssertEqual(blog.findingsSummary, "1 check to fix")
    }

    /// The findings themselves are KEPT. The panel is a view of them, and
    /// clearing is a judgement about what to show, not a reason to destroy the
    /// record of what the checks found (L116).
    func testClearingKeepsTheFindingItself() {
        var caption = DayCaption()
        caption.applyFindings([finding("foreign_handle", "@mikepacific0")],
                              checkedCaption: "the caption")

        caption.clearFinding("foreign_handle|@mikepacific0")

        XCTAssertEqual(caption.findings.count, 1)
    }

    func testClearingTheSameFindingTwiceRecordsItOnce() {
        var caption = DayCaption()
        caption.applyFindings([finding("a", "one")], checkedCaption: "x")

        caption.clearFinding("a|one")
        caption.clearFinding("a|one")

        XCTAssertEqual(caption.clearedFindings, ["a|one"])
    }

    // MARK: - It does not outlive the text it was about

    func testAFreshSetOfFindingsIsJudgedFromNothing() {
        // A regenerated caption is new text and the checks ran again, so a
        // clearance recorded against the old text must not hide a finding
        // about the new one (L15).
        var caption = DayCaption()
        caption.applyFindings([finding("a", "one")], checkedCaption: "first")
        caption.clearFinding("a|one")

        caption.applyFindings([finding("a", "one")], checkedCaption: "second")

        XCTAssertTrue(caption.clearedFindings.isEmpty)
        XCTAssertEqual(caption.openFindings.count, 1)
    }

    func testABlogsClearancesGoWithItsNextCheckToo() {
        var blog = BlogOutput()
        blog.applyFindings([finding("a", "one")], checkedBody: "first")
        blog.clearFinding("a|one")

        blog.applyFindings([finding("a", "one")], checkedBody: "second")

        XCTAssertEqual(blog.openFindings.count, 1)
    }

    // MARK: - Stored

    func testAClearanceSurvivesTheNextLaunch() throws {
        var caption = DayCaption()
        caption.applyFindings([finding("a", "one")], checkedCaption: "x")
        caption.clearFinding("a|one")

        let back = try JSONDecoder().decode(
            DayCaption.self, from: try JSONEncoder().encode(caption))

        XCTAssertEqual(back.clearedFindings, ["a|one"])
        XCTAssertTrue(back.openFindings.isEmpty)
    }

    func testACaptionSavedBeforeThisExistedStillDecodes() throws {
        let json = Data(#"{"caption": "hello"}"#.utf8)

        let caption = try JSONDecoder().decode(DayCaption.self, from: json)

        XCTAssertTrue(caption.clearedFindings.isEmpty)
    }
}
