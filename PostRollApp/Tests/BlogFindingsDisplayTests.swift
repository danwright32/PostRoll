import XCTest

/// Pins how the deterministic blog checks (#201) reach Dan's screen.
///
/// Two things this has to get right. They ran but were invisible: findings
/// went to stderr and the Python result while `BlogOutput` decoded neither, so
/// the whole enforcement pass may as well not have shipped. And a finding
/// describes the body as GENERATED, so once Dan edits that body the finding
/// may already be fixed; it must stop presenting itself as current rather than
/// outlive the correction.
final class BlogFindingsDisplayTests: XCTestCase {

    private func blog(_ findings: [BlogFinding],
                      body: String = "draft",
                      checked: String = "draft") -> BlogOutput {
        var out = BlogOutput(title: "T", body: body)
        out.generatedBody = body
        out.applyFindings(findings, checkedBody: checked)
        return out
    }

    private let one = BlogFinding(code: "invented_number",
                                  message: "No count in the source data means no number in the post.",
                                  detail: "'thirty' does not appear in the program data")
    private let two = BlogFinding(code: "alt_text_length",
                                  message: "Alt text must be 15 to 25 words.",
                                  detail: "a.jpg: 34 words.")

    // MARK: - summary

    func testNoFindingsShowsNothing() {
        XCTAssertNil(BlogFindingsDisplay.summary(blog: blog([])))
    }

    func testOneFindingIsCountedInTheSingular() {
        XCTAssertEqual(BlogFindingsDisplay.summary(blog: blog([one])), "1 check to fix")
    }

    func testSeveralFindingsAreCounted() {
        XCTAssertEqual(BlogFindingsDisplay.summary(blog: blog([one, two])), "2 checks to fix")
    }

    // MARK: - staleness once the draft is edited

    func testFindingsAreCurrentWhileTheBodyIsUntouched() {
        XCTAssertFalse(BlogFindingsDisplay.isStale(blog: blog([one])))
    }

    func testFindingsGoStaleOnceTheBodyIsEdited() {
        let edited = blog([one], body: "Dan fixed it", checked: "draft")
        XCTAssertTrue(BlogFindingsDisplay.isStale(blog: edited),
                      "the checks ran against the generated draft, not this text")
    }

    func testAnEditedDraftSaysTheChecksAreAgainstTheOriginal() {
        let edited = blog([one, two], body: "Dan fixed it", checked: "draft")
        XCTAssertEqual(BlogFindingsDisplay.summary(blog: edited),
                       "2 checks against the original draft")
    }

    func testABlogSavedBeforeTheCheckedBodyWasRecordedIsNotTreatedAsStale() {
        // No record of what was checked is not evidence Dan changed anything,
        // and greying out every older event's findings would be worse.
        let unstamped = blog([one], body: "draft", checked: "")
        XCTAssertFalse(BlogFindingsDisplay.isStale(blog: unstamped))
    }

    func testAPhotoSwapRechecksRatherThanGoingStale() {
        // The swap rewrites every marker and re-runs the checks, so its
        // findings describe the NEW body. Inferring staleness from
        // generatedBody reported these as stale the moment they arrived.
        var swapped = BlogOutput(title: "T", body: "body with new markers")
        swapped.generatedBody = "body with old markers"
        swapped.applyFindings([one], checkedBody: "body with new markers")

        XCTAssertFalse(BlogFindingsDisplay.isStale(blog: swapped))
        XCTAssertEqual(BlogFindingsDisplay.summary(blog: swapped), "1 check to fix")
    }

    // MARK: - grouping

    func testRepeatsOfOneCheckCollapseUnderOneHeading() {
        let alt2 = BlogFinding(code: "alt_text_length",
                               message: "Alt text must be 15 to 25 words.",
                               detail: "b.jpg: 31 words.")
        let groups = BlogFindingsDisplay.grouped(findings: [two, one, alt2])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].message, "Alt text must be 15 to 25 words.")
        XCTAssertEqual(groups[0].details, ["a.jpg: 34 words.", "b.jpg: 31 words."])
        XCTAssertEqual(groups[1].message, "No count in the source data means no number in the post.")
    }

    func testGroupsKeepFirstAppearanceOrder() {
        let groups = BlogFindingsDisplay.grouped(findings: [one, two])
        XCTAssertEqual(groups.map(\.code), ["invented_number", "alt_text_length"])
    }

    func testAFindingWithNoDetailStillShowsItsMessage() {
        let bare = BlogFinding(code: "stacked_photos", message: "Two photos with no prose between them.")
        let groups = BlogFindingsDisplay.grouped(findings: [bare])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].details.isEmpty)
    }
}

/// #205: the title is generated, stored, shown in the header and written on
/// export, and Dan still typed it by hand on both recent posts, because the
/// surface he copies from carried the body alone.
final class BlogDraftTextTests: XCTestCase {

    func testTheTitleLeadsTheCopiedText() {
        let text = BlogDraftText.copyText(title: "The One-Man Odyssey at Greenwich House Theater",
                                          body: "First paragraph.")
        XCTAssertEqual(text, "# The One-Man Odyssey at Greenwich House Theater\n\nFirst paragraph.")
    }

    func testAMissingTitleJustGivesTheBody() {
        XCTAssertEqual(BlogDraftText.copyText(title: "  ", body: "Body."), "Body.")
    }

    func testAnEmptyBodyStillGivesTheHeading() {
        XCTAssertEqual(BlogDraftText.copyText(title: "T", body: ""), "# T")
    }

    func testTheHeadingIsNotAddedTwice() {
        // Copying a post that was pasted back in must not stack headings.
        let once = BlogDraftText.copyText(title: "T", body: "# T\n\nBody.")
        XCTAssertEqual(once, "# T\n\nBody.")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(BlogDraftText.copyText(title: " T ", body: "\n\nBody.\n\n"),
                       "# T\n\nBody.")
    }
}
