import XCTest
import SwiftUI

/// #1405: the finished-export screen now carries each failed day's reason, and
/// it has to still fit the window.
///
/// The reason was withheld on the premise that it is a wall of ffmpeg output
/// (#262). Retiring that premise was a measurement, not an opinion: the real
/// failures recorded in `tests/fixtures/real_failure_text.json` run 22 to 311
/// characters. Shipping it uncapped is only safe while that stays true, and
/// `ExportDoneSummary` is a plain stack with no scrolling, so a message long
/// enough pushes "Open in Finder" and "Done" off the bottom and strands a
/// finished export on a screen with no way out (#182 is what that costs).
///
/// So this measures the SCREEN at the WORST text the fixture holds, rather than
/// asserting a character count somewhere. A cap chosen by eye would be a number
/// nobody measured; this fails if the real failures ever outgrow the window,
/// which is the thing actually worth knowing.
@MainActor
final class ExportFailureScreenFitTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable { let name: String; let text: String }
        let cases: [Case]
    }

    /// Every real failure text, longest first.
    private func recordedFailures() throws -> [Fixture.Case] {
        let data = try RepoFixture.data("tests/fixtures/real_failure_text.json")
        return try JSONDecoder().decode(Fixture.self, from: data)
            .cases.sorted { $0.text.count > $1.text.count }
    }

    /// The detail pane's width, not the window's: the export screen sits beside
    /// the event list, so measuring at 1200 would measure a column the screen
    /// never gets.
    private let paneWidth: CGFloat = 900

    func testTheWorstRealFailureStillFitsTheWindow() throws {
        let worst = try XCTUnwrap(recordedFailures().first)
        let message = try XCTUnwrap(MediaErrorSummary.sentence(["thursday": worst.text]))

        let view = ExportDoneSummary(folderName: "2026-08-19 DiGangi With A G",
                                     mediaError: message,
                                     mediaWarning: nil)
        let renderer = ImageRenderer(content: ZStack {
            Color.cream
            view
        }.frame(width: paneWidth))
        let height = try XCTUnwrap(renderer.nsImage?.size.height)

        XCTAssertLessThanOrEqual(
            height, WindowMetrics.defaultHeight,
            "the export screen does not scroll, so at \(worst.text.count) characters "
            + "(\(worst.name)) it is \(Int(height))pt tall against a "
            + "\(Int(WindowMetrics.defaultHeight))pt window and the way out is off the bottom")
    }

    func testTheMeasurementWouldNoticeAScreenThatDidNotFit() throws {
        // The positive control. Without it the assertion above is satisfied by
        // a renderer that reports the same height whatever it is given, and a
        // guard that cannot fail is not a guard (L1, L159).
        let short = try XCTUnwrap(MediaErrorSummary.sentence(["thursday": "it failed"]))
        let long = try XCTUnwrap(MediaErrorSummary.sentence(
            ["thursday": String(repeating: "a wall of output ", count: 400)]))

        func height(_ message: String) throws -> CGFloat {
            let renderer = ImageRenderer(content: ZStack {
                Color.cream
                ExportDoneSummary(folderName: "F", mediaError: message, mediaWarning: nil)
            }.frame(width: paneWidth))
            return try XCTUnwrap(renderer.nsImage?.size.height)
        }

        XCTAssertGreaterThan(try height(long), try height(short),
                             "the measurement does not respond to the message at all")
        XCTAssertGreaterThan(try height(long), WindowMetrics.defaultHeight,
                             "a message this long must be measurable as not fitting")
    }
}
