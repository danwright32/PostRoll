import SwiftUI
import XCTest

/// A day's clip editing is not offered while that day is rebuilding (#732).
///
/// Since #728 an action taken on a day already rebuilding is refused with a
/// message rather than starting a second run over the same MP4, which is
/// correct and is a worse experience than not offering it: a control that looks
/// available and then declines teaches Dan to distrust it, and the state was
/// already known, since the screen holds `regeneratingDays`.
///
/// The mockup's menu, the collage controls, the B&W pair and the inline reel
/// assignment each already take that flag. Friday's clip editor did not, so its
/// reorder, include and exclude, crop, swap, title card mute and re-cut stayed
/// live for the whole minute-plus a rebuild takes.
///
/// Measured rather than asserted from the view tree: disabled controls draw
/// differently, so the flag having an effect is a difference on the page. Both
/// renders are taken at one fixed size so the difference is the controls
/// changing rather than the canvas growing (L146).
@MainActor
final class RebuildingDayControlsTests: XCTestCase {

    private let canvas = CGSize(width: 420, height: 260)

    private func clips() -> [ReelClipOverride] {
        [ReelClipOverride(clipPath: "/clips/first.mov", order: 0,
                          included: true, trimIn: 0, trimOut: 2),
         ReelClipOverride(clipPath: "/clips/second.mov", order: 1,
                          included: true, trimIn: 0, trimOut: 3)]
    }

    private func rendered(isRegenerating: Bool) throws -> NSBitmapImageRep {
        try WordFootprint.hosted(
            FridayClipEditor(entries: clips(),
                             hasOverride: true,
                             onApply: { _ in },
                             onSwap: { _ in },
                             onRecutWithAI: {},
                             titleCardMuted: false,
                             onToggleTitleCard: {},
                             isRegenerating: isRegenerating)
                .padding(Spacing.lg)
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                .background(PaintedSurfaces.page),
            size: canvas,
            wordless: false)
    }

    func testTheClipEditorLooksUnavailableWhileTheDayRebuilds() throws {
        let live = try rendered(isRegenerating: false)
        let rebuilding = try rendered(isRegenerating: true)

        let changed = WordFootprint.share(rebuilding, live)
        XCTAssertGreaterThan(
            changed, WordFootprint.drawn,
            "the clip editor draws identically whether or not Friday is "
            + "rebuilding (\(changed) of the page differs), so every control in "
            + "it invites a click that will be refused")
    }

    func testTheMeasurementSeesNothingWhenNothingChanged() throws {
        // The control. A comparison that reported a difference between a render
        // and itself would pass the test above whatever the editor did (L1).
        let once = try rendered(isRegenerating: true)
        let again = try rendered(isRegenerating: true)

        XCTAssertLessThanOrEqual(WordFootprint.share(once, again), WordFootprint.drawn,
                                 "two identical renders differ, so the measurement "
                                 + "is reporting something other than the content")
    }

    func testTheEditorStillDrawsWhileRebuilding() throws {
        // Disabled, not gone. Removing the editor for the duration would also
        // pass the first test, and it would take the clip list off screen at
        // the moment Dan is watching that rebuild (L10, L187).
        let rebuilding = try rendered(isRegenerating: true)
        let nothing = try WordFootprint.hosted(
            Color.clear
                .frame(width: canvas.width, height: canvas.height)
                .background(PaintedSurfaces.page),
            size: canvas, wordless: false)

        XCTAssertGreaterThan(WordFootprint.share(rebuilding, nothing), WordFootprint.drawn,
                             "the clip editor draws nothing at all while the day "
                             + "rebuilds, so the clips vanish rather than resting")
    }
}
