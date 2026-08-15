import XCTest
import SwiftUI

/// The panel that reports the deterministic checks, drawn by one view rather
/// than two (#603).
///
/// It existed twice in `CaptionReviewView`, once for the caption's checks and
/// once for the blog's, about 81% identical. The difference was not a decision:
/// the caption's panel was one labelled group to VoiceOver and the blog's was
/// loose fragments, and the same fix for a count drawn in the colour of its own
/// wash had to be applied to both in #600.
@MainActor
final class FindingsPanelTests: XCTestCase {

    // MARK: - There is one of it

    /// Counted through the grouping call, which is what a findings panel does
    /// and nothing else in a view file does.
    func testOnlyOneViewGroupsTheFindings() throws {
        var drawers: [String] = []
        for relative in try sourceFiles() where try source(relative)
            .contains("FindingsDisplay.grouped(") {
            drawers.append(relative)
        }

        XCTAssertEqual(drawers.count, 1, """
            \(drawers.count) places build a findings panel: \
            \(drawers.joined(separator: ", ")). Two copies of this panel drifted \
            into reading as one labelled group on one screen and as loose fragments \
            on the other, and one colour fix had to be applied to both.
            """)
    }

    /// Whatever the panel reports, it says what the checks were about.
    ///
    /// The caption's copy carried this and the blog's did not, so the same
    /// panel was a labelled group in one place and a heap of unlabelled text in
    /// the other.
    func testThePanelIsOneLabelledGroup() throws {
        let code = try source("Views/FindingsPanel.swift")

        XCTAssertTrue(code.contains("accessibilityElement(children: .contain)"), """
            The findings panel no longer collapses into one element, so VoiceOver \
            reads its heading, its stale note and every finding as separate stops.
            """)
        XCTAssertTrue(code.contains("accessibilityLabel"), """
            The findings panel no longer carries a label, so a person hearing it has \
            no idea whether these checks are about the caption or the draft.
            """)
    }

    // MARK: - The words it says

    /// The stale sentence names what it ran against, from one place.
    ///
    /// Two hand-written copies said "the caption as generated" and "the draft as
    /// generated" with the same two verbs in a different order, which is one
    /// sentence written twice rather than two sentences.
    func testTheStaleNoteNamesWhatTheChecksRanAgainst() {
        let caption = FindingsDisplay.staleNote(subject: "caption")
        let draft = FindingsDisplay.staleNote(subject: "draft")

        XCTAssertTrue(caption.contains("the caption as generated"),
                      "the stale note has to name what the checks ran against, or it "
                      + "reads as though something else on screen is out of date")
        XCTAssertTrue(draft.contains("the draft as generated"), "same for the blog")
        XCTAssertNotEqual(caption, draft,
                          "the two subjects have to produce different sentences, or "
                          + "the subject is not reaching the copy")
        XCTAssertEqual(caption.replacingOccurrences(of: "caption", with: "draft"), draft,
                       "beyond the subject the sentence has to be the same one, or "
                       + "this is two pieces of copy wearing one function")
    }

    /// The panel says how many and how old, from the shipping summary rather
    /// than from words typed here.
    func testTheHeadingComesFromTheSharedSummary() {
        let fresh = FindingsDisplay.summary(count: 3, stale: false, subject: "caption")
        let stale = FindingsDisplay.summary(count: 3, stale: true, subject: "caption")

        XCTAssertNotNil(fresh)
        XCTAssertNotEqual(fresh, stale,
                          "a fresh panel and a stale one have to say different things, "
                          + "or the person is told nothing about whether the checks "
                          + "still describe what is on screen")
    }

    // MARK: - Reading the tree

    private func sourceFiles() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()

        // A sweep that reads nothing objects to nothing (L98).
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep found \(files.count) source files, so it is "
                             + "proving nothing about the ones it did not read")
        return files
    }

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/\(relative)")
        return SwiftSourceText.withoutComments(
            try String(contentsOf: url, encoding: .utf8))
    }
}
