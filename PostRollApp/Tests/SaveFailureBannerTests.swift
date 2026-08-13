import XCTest

/// The save-failure banner carries the control that can clear it (#446).
///
/// `BannerLegibilityTests` renders it and measures its ink, which proves the
/// MESSAGE is drawn and says nothing about whether the retry is there: removing
/// the action leaves the text exactly as legible. A notice that names a problem
/// and offers nowhere to go leaves the reader precisely where they were (L80), and
/// here that reader has been told his last hour of edits exist only on screen.
final class SaveFailureBannerTests: XCTestCase {

    private func windowSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/MainWindowView.swift")
        // Comments stripped: the prose explaining the retry must not be able to
        // satisfy a check for the retry (L103).
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheFailureBannerIsDrawnFromTheFailureItself() throws {
        let code = try windowSource()

        XCTAssertTrue(code.contains("appState.saveFailure"),
                      "nothing in the window reads the save failure, so it is a value "
                      + "with no reader and the banner cannot appear at all")
    }

    func testItOffersTheRetryThatCanClearIt() throws {
        let code = try windowSource()

        XCTAssertTrue(code.contains("SaveFailureNotice.retryLabel"),
                      "the banner does not offer the labelled retry")
        XCTAssertTrue(code.contains("appState.retrySave()"),
                      "the retry control is drawn but wired to nothing, so pressing it "
                      + "leaves the banner exactly where it was")
    }
}
