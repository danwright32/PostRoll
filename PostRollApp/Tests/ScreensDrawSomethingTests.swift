import XCTest
import SwiftUI
import AppKit

/// #947: a screen on the review sheet has to have actually drawn something.
///
/// `TopLevelScreenCoverageTests` requires every screen `EventDetailView` can
/// show to have a surface named `screen: <TypeName>` on the sheet. It checks the
/// NAME. A surface whose renderer produced a blank image, or an error state, or
/// a screen that failed to lay out, satisfies it completely.
///
/// That is the shape this project keeps recording lessons about: an absent thing
/// and a correctly drawn thing giving the same answer (L98), and a check
/// satisfied by a picture of a state nobody chose (L84). The rule was written to
/// close exactly that gap one level up and left it open one level down.
///
/// ## Why not ink
///
/// A screen paints its own background, its header and its chrome, and every one
/// of those measures as presence. A page with no words at all still has plenty
/// of ink (L141, L146).
///
/// So: the difference method the rest of this project uses. Render each screen
/// twice, once normally and once with its words switched off through
/// `WordFootprint`'s wordless path, and require the two to differ. What differs
/// between them is the type and nothing else.
@MainActor
final class ScreensDrawSomethingTests: XCTestCase {

    /// How much of a screen has to be words.
    ///
    /// Measured on the real screens rather than chosen. On this Mac on
    /// 2026-09-04 the eight surfaces ran from 0.0062 (OCRProgressView, which is
    /// a spinner, a line and an estimate) to 0.0378 (PhotoAssignmentView, which
    /// is a grid of labelled days). This sits at about a third of the lowest
    /// real reading: below the whole band, and far above zero, rather than
    /// inside the dense middle where a small shift would carry several screens
    /// across at once (L172).
    ///
    /// Deliberately near zero, because the defect it separates from is not "a
    /// bit less type". It is a blank page, an error state, or a layout that
    /// collapsed, and all three measure at or near nothing. This is not a
    /// legibility check: `HostedControlLegibilityTests` is that, and it runs
    /// over the same surfaces.
    private static let mustBeWords = 0.002

    private func screens() -> [(name: String, render: (Bool) throws -> NSBitmapImageRep)] {
        HostedControlLegibilityTests().wholeScreens
    }

    func testTheSweepHasTheScreensToMeasure() {
        // The positive control. An empty list would report every screen as
        // drawing its words, which is what the defect looks like (L98, L100).
        let names = screens().map(\.name)

        XCTAssertGreaterThanOrEqual(names.count, 8,
                                    "only \(names.count) whole screens are on "
                                    + "the sheet: \(names)")
    }

    func testEveryScreenOnTheSheetDrewItsWords() throws {
        var thin: [String] = []
        for screen in screens() {
            let whole = try screen.render(false)
            let wordless = try screen.render(true)
            let share = WordFootprint.share(whole, wordless)
            if share <= Self.mustBeWords { thin.append("\(screen.name): \(share)") }
        }

        XCTAssertTrue(thin.isEmpty,
                      "these screens are on the review sheet and drew no words, "
                      + "so the picture reviewing them is of a blank page, an "
                      + "error state or a layout that collapsed, and it is "
                      + "indistinguishable from one that was reviewed and found "
                      + "fine (#947): \(thin)")
    }

    func testTheMeasurementCanTellABlankScreenFromARealOne() throws {
        // The positive control, and the one that matters most here (L159).
        // Without it "every screen drew its words" is satisfied by a
        // measurement that says yes to anything, including to the blank page
        // this exists to catch. Both directions, on the same harness the check
        // above uses rather than a second one (L48).
        let blank = try WordFootprint.hosted(
            Color.cream.frame(width: 400, height: 300),
            size: CGSize(width: 400, height: 300), wordless: false)
        let blankAgain = try WordFootprint.hosted(
            Color.cream.frame(width: 400, height: 300),
            size: CGSize(width: 400, height: 300), wordless: true)

        XCTAssertLessThanOrEqual(WordFootprint.share(blank, blankAgain),
                                 Self.mustBeWords,
                                 "a page with no words at all measures above "
                                 + "the floor, so the floor cannot catch one")

        let real = try screens()[0].render(false)
        let realWordless = try screens()[0].render(true)
        XCTAssertGreaterThan(WordFootprint.share(real, realWordless),
                             Self.mustBeWords,
                             "a real screen measures at or below the floor, so "
                             + "the check could never pass and nobody could "
                             + "satisfy it (L109)")
    }
}
