import XCTest

/// #282: the blog draft's markdown is assembled in one place.
///
/// `# title\n\nbody` was written by hand in three: the exporter writing
/// `0. Blog/draft.md`, the Python CLI writing the same file, and the clipboard
/// text on the review screen. That is the dual-CAPTIONS.txt parity hazard with
/// an extra copy, and two of the three are invisible to anyone editing the
/// first. The clipboard's version was the careful one, so its rules are the
/// contract and the other two now go through it.
///
/// `tests/fixtures/blog_draft.json` states the rules once; `tests/
/// test_blog_draft_text.py` asserts the Python side satisfies the same file.
final class BlogDraftTextContractTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let _what: String
            let title: String
            let body: String
            let expected: String
        }
        let cases: [Case]
    }

    func testSwiftSatisfiesTheSharedDraftContract() throws {
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: try RepoFixture.data("tests/fixtures/blog_draft.json"))
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 6,
                                    "a gutted fixture would pass vacuously")

        for c in fixture.cases {
            XCTAssertEqual(BlogDraftText.copyText(title: c.title, body: c.body),
                           c.expected, c._what)
        }
    }

    func testNoScreenBuildsTheHeadingByHand() throws {
        // One renderer, not one per writer. Derived from the source so a fourth
        // copy added later is caught on the day it lands.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  url.lastPathComponent != "BlogFindingsDisplay.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains(##"# \(blog.title)"##) || text.contains(##"# \(title)"##) {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "these files assemble the draft heading themselves: \(offenders)")
    }
}
