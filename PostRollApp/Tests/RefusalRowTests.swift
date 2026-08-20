import SwiftUI
import XCTest

/// A refusal is not hidden by whatever else the screen has to say (#731).
///
/// The caption review screen showed one notice at a time and let the week
/// regeneration's outcome win it: `outcome(...)?.failure ?? refusedAction`. That
/// is a reasonable rule for two things competing for one slot, and it made
/// everything refused AFTERWARDS silent. With a stopped-early week banner on
/// screen, a photo set too small for a collage, a file that would not copy, or a
/// day already rebuilding all produced no visible response at all, and the action
/// did not happen either. The only signal that the click did nothing was gone,
/// which leaves pressing it again as the only diagnosis available (L148).
///
/// Measured rather than read off the view tree: what matters is that the sentence
/// reaches the page, and the two renders are taken at one fixed size so the
/// difference is the row appearing rather than the canvas growing (L146).
@MainActor
final class RefusalRowTests: XCTestCase {

    /// Big enough for both banners at this width, and fixed, because two
    /// renders of different sizes cannot be compared at all.
    private let canvas = CGSize(width: 640, height: 320)

    private let weekFailure = "The week stopped early: Claude returned no captions for Wednesday."
    private let refusal = "The Wednesday collage needs at least 2 photos (you picked 1)."

    private func rendered(week: String?, refused: String?) throws -> NSBitmapImageRep {
        try WordFootprint.hosted(
            CaptionReviewNotices(regenerateError: week, refusal: refused)
                .padding(Spacing.lg)
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                .background(PaintedSurfaces.page),
            size: canvas,
            wordless: false)
    }

    func testARefusalReachesThePageWithAWeekBannerAlreadyOnIt() throws {
        let banner = try rendered(week: weekFailure, refused: nil)
        let both = try rendered(week: weekFailure, refused: refusal)

        let appeared = WordFootprint.share(both, banner)
        XCTAssertGreaterThan(
            appeared, WordFootprint.drawn,
            "with the week's banner on screen, adding a refusal changed \(appeared) "
            + "of the page, which is nothing: the refusal is being swallowed by "
            + "the banner and the control that declined looks broken")
    }

    func testTheRefusalAloneReachesThePage() throws {
        // The same question with nothing to compete with, so a failure above
        // says the COMPETITION is what loses the row rather than the row never
        // drawing at all. Distinct causes, distinct measurements (L11).
        let empty = try rendered(week: nil, refused: nil)
        let alone = try rendered(week: nil, refused: refusal)

        XCTAssertGreaterThan(WordFootprint.share(alone, empty), WordFootprint.drawn,
                             "a refusal with nothing else on screen does not draw")
    }

    func testTheMeasurementSeesNothingWhenNothingChanged() throws {
        // The control. A comparison that reports a difference between a render
        // and itself would pass both tests above whatever the view did (L1).
        let once = try rendered(week: weekFailure, refused: refusal)
        let again = try rendered(week: weekFailure, refused: refusal)

        XCTAssertLessThanOrEqual(WordFootprint.share(once, again), WordFootprint.drawn,
                                 "two identical renders differ, so the measurement "
                                 + "is reporting something other than the content")
    }
}
