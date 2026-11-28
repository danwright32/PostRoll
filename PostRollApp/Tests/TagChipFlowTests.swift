import XCTest
import SwiftUI
import AppKit

/// The tagging sheet's chips, measured as AppKit lays them out in the sheet's
/// own column.
@MainActor
final class TagChipFlowTests: XCTestCase {

    private let column = TagChipMetrics.sheetColumnWidth

    /// The shape of the longest labels a programme produces: a name, a role
    /// that is a phrase rather than a word, and a handle on the end.
    private let long = "Jo Example director of the example chorus holiday choir @joexamplemusic"
    private let short = "Ada Example vocalist"

    private func flow(_ labels: [String]) -> TagSuggestionFlow {
        TagSuggestionFlow(suggestions: labels.map { PhotoTagSuggestion(token: $0, display: $0) },
                          onPick: { _ in })
    }

    /// What the chips need when nothing limits their width.
    private func unlimited(_ labels: [String]) -> CGSize {
        NSHostingView(rootView: flow(labels)).fittingSize
    }

    /// How tall the chips are when held to `width`.
    private func height(_ labels: [String], width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: flow(labels).frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testALabelLongerThanTheColumnWrapsInsideItsChip() {
        // The control first: a label that fitted the column would pass
        // whatever the chip did with a long one.
        XCTAssertGreaterThan(unlimited([long]).width, column,
                             "the long label fits the column on one line, so this measures "
                             + "nothing about a chip that is too wide")

        let oneLine = height([short], width: column)
        let wrapped = height([long], width: column)

        XCTAssertGreaterThan(wrapped, oneLine * 1.5, """
            a label wider than the column is \(wrapped)pt tall against \(oneLine)pt for one \
            that fits, so it is still on one line and its end is past the column's edge
            """)
    }

    func testAShortChipIsNoTallerInTheColumnThanOutOfIt() {
        XCTAssertEqual(height([short], width: column), unlimited([short]).height, accuracy: 0.5)
    }

    func testTheFadeOverTheChipsNeverCoversAWholeChip() {
        let chip = unlimited([short]).height

        XCTAssertLessThanOrEqual(TagChipMetrics.fadeDepth, chip / 2, """
            the fade is \(TagChipMetrics.fadeDepth)pt deep and a chip is \(chip)pt tall, so a \
            chip under the fade is washed out whole and reads as one that cannot be picked
            """)
    }
}
