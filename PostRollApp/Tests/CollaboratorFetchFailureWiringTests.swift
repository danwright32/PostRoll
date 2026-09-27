import XCTest

/// The second half of #1431: the fetch owner's own answer reaches the pick,
/// and the panel leads with what it has to say.
///
/// Its own file rather than beside the pick's tests, so a change here does not
/// select every guard those tests prove (#1438 outran the guard deadline).
final class CollaboratorFetchFailureWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        SwiftSourceText.withoutComments(
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/\(path)"), encoding: .utf8))
    }

    func testThePanelLeadsWithWhatItHasToSayBeforeTheRows() throws {
        // The notes explain why the rows look as they do, so they sit under the
        // headline rather than under the last of seven "not counted" rows,
        // where nobody scrolls (#1431, L609).
        let code = try source("Views/CollaboratorPanel.swift")
        let notes = try XCTUnwrap(code.range(of: "ForEach(result.notes"),
                                  "the panel no longer draws its notes at all")
        let rows = try XCTUnwrap(code.range(of: "ForEach(Array(result.suggested"))
        XCTAssertLessThan(notes.lowerBound, rows.lowerBound,
                          "the notes are drawn after the rows, below every account")
    }

    func testBothSurfacesPassTheFetchOwnersAnswer() throws {
        // Built is not wired (L3). The review screen and the export each have
        // to hand over the fetch owner's own fact, not a literal false.
        XCTAssertTrue(try source("Views/CaptionReviewView.swift")
                        .contains("fetchFailed: accountNumbers.fetchFailed"),
                      "the review screen does not tell the pick the fetch failed")
        XCTAssertTrue(try source("Services/ExportManager.swift")
                        .contains("collaboratorFetchFailed: fetchFailed"),
                      "the export does not tell CAPTIONS.txt the fetch failed")
    }
}
