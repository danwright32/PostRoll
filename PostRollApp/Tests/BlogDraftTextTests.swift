import XCTest

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
