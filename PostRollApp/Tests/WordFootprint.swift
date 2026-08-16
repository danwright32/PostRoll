import XCTest
import SwiftUI
import AppKit

/// Draws no type at all (#612).
///
/// The generic way to ask a shipping view what its words are worth. #607 could
/// put a `wordless` flag on the reading screen because that screen was being
/// written; the surfaces measured across this suite are shipping views that
/// know nothing about being measured, and a flag on each of them would be a
/// change to the app for the benefit of a test.
///
/// Layout is untouched, because only the drawing is replaced: every fill,
/// border, symbol and button stays exactly where it was, so the difference
/// between a render with this and one without is the type and nothing else.
///
/// Applied to ONE side of the comparison only. Putting a renderer of ours on
/// the words-on side too changes the path the type takes, and that path is the
/// subject: the busy pill, whose label ImageRenderer is known to drop, drew its
/// label perfectly through a custom renderer.
struct WordSwitch: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {}
}

/// What a surface's words are worth, and the one floor they are judged against
/// (#614).
///
/// This replaces three thresholds. `BannerLegibilityTests` asked for 0.01 of a
/// surface to be ink, `PhotoLightboxTests` for 0.005, and the reading screen
/// added by #607 for 0.005 again. Each was measured honestly against its own
/// surface, and the pattern was the problem: a sparse screen earned a lower bar
/// because that is what it happened to measure, which is the direction a
/// threshold drifts, and nothing would ever report it. A floor lowered to fit a
/// screen reads exactly like a floor sized for it.
///
/// Two changes make one number enough for every surface in the suite.
///
/// **Ink was the wrong quantity.** It is the share of pixels unlike the
/// commonest colour, so it counts the fill, the border, the symbol and the
/// button along with the type, and a surface that is mostly its own chrome
/// reads as full whatever its words do (#559, L141). It is not even monotone:
/// on three of the measured notices, taking the type away MOVES what the
/// commonest colour is and the number goes UP. A quantity that can rise when
/// content is removed cannot be asked whether content is there, and a floor
/// under it has to be set per surface because it is mostly measuring how much
/// chrome that surface paints.
///
/// **The difference between two renders is the right one.** Draw the surface,
/// draw it again with its words switched off, and compare pixel for pixel: what
/// differs is the type, and nothing about the chrome is in the number at all.
/// A sparse screen and a dense notice are then measured on the same scale, so
/// they can share a floor.
///
/// The floor itself is derived rather than chosen. Two renders of the same view
/// differ by NOTHING, which `testTheFootprintOfNothingIsNothing` measures on
/// every run rather than assuming, so any figure above zero is type reaching the
/// page. `drawn` is a margin over that zero, and every surface in the suite sits
/// far above it:
///
/// * the 11pt Go Back on the failure screen, the smallest single thing measured
///   anywhere, 0.0013;
/// * the lightbox, the sparsest whole screen in the app, 0.0093;
/// * the thirty-eight notices, 0.0097 to 0.0761.
///
/// A surface whose type does not reach the page reads 0.0000, not merely small.
enum WordFootprint {

    /// The margin over a measured zero that counts as type on the page.
    ///
    /// One number for every surface, which is the whole point: it is not a
    /// share of any particular screen, it is the distance from "no difference
    /// at all".
    static let drawn = 0.0004

    /// The share of pixels that differ between two renders of one view.
    ///
    /// Sampled every other pixel in both directions, which is what the ink
    /// measurement this replaces did, at a quarter of the reads.
    static func share(_ whole: NSBitmapImageRep, _ without: NSBitmapImageRep) -> Double {
        guard whole.pixelsWide == without.pixelsWide,
              whole.pixelsHigh == without.pixelsHigh else { return 0 }

        func luminance(_ c: NSColor) -> Double {
            0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        }

        var differing = 0
        var sampled = 0
        for y in Swift.stride(from: 0, to: whole.pixelsHigh, by: 2) {
            for x in Swift.stride(from: 0, to: whole.pixelsWide, by: 2) {
                guard let a = whole.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = without.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                sampled += 1
                if abs(luminance(a) - luminance(b)) > 0.02 { differing += 1 }
            }
        }
        guard sampled > 0 else { return 0 }
        return Double(differing) / Double(sampled)
    }

    /// The share of pixels differing noticeably from the commonest colour,
    /// which IS the background.
    ///
    /// The quantity `share` replaced, kept because two checks are genuinely
    /// ABOUT it: a bare `ProgressView` has no words and still measures as
    /// plenty of ink, which is the record of why it was the wrong question to
    /// ask a surface. One copy rather than the two that had grown, one per
    /// harness.
    static func ink(_ rep: NSBitmapImageRep) -> Double {
        var luminances: [Double] = []
        for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in Swift.stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                luminances.append(0.299 * c.redComponent
                                  + 0.587 * c.greenComponent
                                  + 0.114 * c.blueComponent)
            }
        }
        guard !luminances.isEmpty else { return 0 }
        let background = luminances.sorted()[luminances.count / 2]
        return Double(luminances.filter { abs($0 - background) > 0.12 }.count)
            / Double(luminances.count)
    }

    /// One view through `ImageRenderer`, as it is, or with its words switched
    /// off.
    ///
    /// The words-on render carries no modifier of any kind, which is not a
    /// detail: putting one on that side changes the path the type takes and
    /// dissolves the very thing being looked for (#612).
    @MainActor
    static func imageRendered(_ content: some View,
                              wordless: Bool) throws -> NSBitmapImageRep {
        let renderer = wordless
            ? ImageRenderer(content: AnyView(content.textRenderer(WordSwitch())))
            : ImageRenderer(content: AnyView(content))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the view produced no image at all")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    /// One view through a real AppKit host, as it is, or with its words
    /// switched off.
    ///
    /// `size` nil renders it at the size it asks for. The two renders must be
    /// the same size or the comparison is meaningless, and they are: switching
    /// the drawing of type off does not change its layout.
    @MainActor
    static func hosted(_ content: some View, size: CGSize? = nil,
                       wordless: Bool) throws -> NSBitmapImageRep {
        let root = wordless
            ? AnyView(content.textRenderer(WordSwitch()))
            : AnyView(content)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "AppKit produced no bitmap to draw into")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
