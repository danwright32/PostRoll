import XCTest
import SwiftUI
import AppKit

/// What appearance a hosted render is drawn in (#918).
///
/// The app pins itself to light: `.preferredColorScheme(.light)` on the window
/// and `NSApplication.shared.appearance = NSAppearance(named: .aqua)` on the
/// application. `PaintedSurfaces` already resolves its dynamic system colours
/// under that same appearance, and says why: a colour read under whatever the
/// test process happens to have is a colour the app never draws.
///
/// The renderer had the other half missing. `NSHostingView` was given no
/// appearance, so anything AppKit drew for ITSELF, a Form's background, a
/// TextField's bezel, a Picker, followed the machine instead. This was found by
/// putting the Settings screen on the review sheet (#918) on a Mac in dark
/// mode: the whole Form came out near black with the app's own light-mode type
/// on top of it, which is a picture of a screen the app cannot produce, and it
/// would have been reviewed as if it were one.
///
/// Nothing went red, and nothing could have. Every legibility check reads
/// colours this app NAMES, and those were pinned already; the platform chrome
/// underneath them is what moved, and no check measures that (which is #930).
///
/// The appearance is SET here rather than inherited, because a test that only
/// fails on a machine in dark mode says nothing at all on a light one, and CI
/// is a light one (L504).
@MainActor
final class RenderAppearanceTests: XCTestCase {

    /// A patch of a colour AppKit owns rather than one this app names, so it
    /// follows the appearance rather than a constant.
    private func drawnWindowBackground() throws -> NSColor {
        let size = CGSize(width: 40, height: 40)
        let rep = try WordFootprint.hosted(
            Color(nsColor: .windowBackgroundColor).frame(width: size.width,
                                                         height: size.height),
            size: size, wordless: false)
        return try XCTUnwrap(rep.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB),
                             "nothing was drawn to read a colour from")
    }

    private func brightness(_ colour: NSColor) -> CGFloat { colour.brightnessComponent }

    func testAHostedRenderIgnoresTheMachinesOwnAppearance() throws {
        let previous = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previous }

        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let underDark = try drawnWindowBackground()

        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let underLight = try drawnWindowBackground()

        XCTAssertEqual(brightness(underDark), brightness(underLight), accuracy: 0.01, """
            the same view renders differently depending on what appearance the \
            machine happens to be in: \(brightness(underDark)) against \
            \(brightness(underLight)). The app pins itself to aqua, so a render \
            that follows the machine is a picture of a screen the app never draws, \
            and on a Mac in dark mode the whole review sheet is one.
            """)
    }

    func testTheRenderIsPinnedToTheAppearanceTheAppUsesRatherThanEitherOne() throws {
        // The check above is satisfied by pinning to EITHER appearance, as long
        // as it is consistent, and dark would satisfy it just as well. This
        // says which one, against the same appearance PaintedSurfaces resolves
        // its own colours under, so the chrome and the type cannot be pinned to
        // opposite halves (L213).
        let previous = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previous }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        let drawn = try drawnWindowBackground()
        let expected = try XCTUnwrap(
            NSColor(PaintedSurfaces.systemFormBackground).usingColorSpace(.sRGB))

        XCTAssertEqual(brightness(drawn), brightness(expected), accuracy: 0.01, """
            the render draws AppKit's window background at \(brightness(drawn)) \
            while PaintedSurfaces resolves the same colour at \(brightness(expected)). \
            The type and the surface under it are pinned to different appearances, \
            which is how a screen ends up correct in every named colour and \
            unreadable on screen.
            """)
    }

    func testTheMeasurementCanTellTheTwoAppearancesApart() throws {
        // The two checks above assert a SAMENESS, and a reading that cannot
        // tell light from dark reports sameness for any input at all (L159).
        // This is the same measurement on a colour that really does move.
        var dark = Color.white
        var light = Color.white
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            dark = Color(nsColor: NSColor.windowBackgroundColor
                .usingColorSpace(.sRGB) ?? .black)
        }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            light = Color(nsColor: NSColor.windowBackgroundColor
                .usingColorSpace(.sRGB) ?? .white)
        }

        XCTAssertGreaterThan(
            abs(brightness(NSColor(light)) - brightness(NSColor(dark))), 0.3,
            "AppKit's window background reads the same in both appearances here, "
            + "so the checks above would pass whatever the renderer did")
    }
}
