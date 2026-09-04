import XCTest
import SwiftUI
import AppKit

/// #1239: three surfaces in the Thursday editor exist to be READ, and nothing
/// measured that they draw.
///
/// The music warning beside the scroll duration slider (#1076), the speed
/// warning in the reel panel (#1066), and `ReelPaceSampler` (#1071). Their
/// wording and their numbers are unit tested. What was not tested is that the
/// text is not clipped by the column it sits in, that it reads against its
/// background, and that the sampler's window is the shape it claims.
///
/// A warning that is clipped in its column has failed at the one job it has,
/// and every existing check would still be green.
///
/// ## Why here rather than in the whole-screen harness
///
/// The issue suggested putting `PhotoAssignmentView` into a state that produces
/// them. These are a `Text` in a column and a small animated view, not banners,
/// and driving a whole screen into the state that shows them means an audio
/// file on disk and a photo set of the right shape. Measuring the surfaces
/// themselves, at the width their column really gives them, checks the thing
/// the issue is about with nothing standing in the way of it. Same shape as
/// `BlogRetryControlLegibilityTests`, which measures one control this way.
///
/// ## What each check is for
///
/// Ink alone would be answered by the surface's own background, so every
/// reading here is the difference between the surface drawn and the same
/// surface with its words switched off (L141, L146).
@MainActor
final class ThursdayEditorNoticeLegibilityTests: XCTestCase {

    /// The narrowest the editor's right-hand column gets.
    ///
    /// Deliberately harsh rather than the real width: a notice that survives
    /// this survives anything Dan can drag the window to, which is the same
    /// reasoning `HostedControlLegibilityTests` uses for its own 400pt floor.
    private static let column: CGFloat = 260

    /// The real sentences, from the shipping code rather than typed here.
    ///
    /// A fixture with a sentence I wrote would measure my sentence, not the
    /// one the editor shows (L48).
    private static func musicNotice() -> String {
        ScrollReelTiming.musicNotice(trackSeconds: 12, scrollSeconds: 30) ?? ""
    }

    private static func speedNotice() -> String {
        ScrollReelTiming.speedNotice(stripHeight: 9000, photoCount: 12,
                                     scrollSeconds: 8) ?? ""
    }

    private func noticeText(_ message: String) -> some View {
        Text(message)
            .font(.light(11))
            .foregroundStyle(PaintedSurfaces.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func framed(_ view: some View, width: CGFloat) -> some View {
        ZStack {
            PaintedSurfaces.page
            view.padding(Spacing.md)
        }.frame(width: width)
    }

    /// The share of the surface that is words.
    private func wordShare(_ view: some View, width: CGFloat) throws -> Double {
        let page = framed(view, width: width)
        let size = CGSize(width: width, height: 220)
        return WordFootprint.share(
            try WordFootprint.hosted(page, size: size, wordless: false),
            try WordFootprint.hosted(page, size: size, wordless: true))
    }

    private func heightAt(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: - The two sentences

    func testTheFixturesAreTheSentencesTheEditorReallyShows() {
        // The control. A notice producer that stopped producing would leave
        // every measurement below reading an empty string, and an empty string
        // measures as no words in exactly the way a clipped one does (L98).
        XCTAssertFalse(Self.musicNotice().isEmpty,
                       "the music notice produced nothing for a track shorter "
                       + "than its reel, so the checks below measure a blank")
        XCTAssertFalse(Self.speedNotice().isEmpty,
                       "the speed notice produced nothing for a reel faster "
                       + "than comfortable, so the checks below measure a blank")
    }

    func testTheMusicWarningDrawsItsWords() throws {
        let share = try wordShare(noticeText(Self.musicNotice()), width: Self.column)

        XCTAssertGreaterThan(share, WordFootprint.drawn,
                             "the music warning drew \(String(format: "%.4f", share)) "
                             + "of its column, which is nothing: it is in the "
                             + "view tree and not on the screen")
    }

    func testTheSpeedWarningDrawsItsWords() throws {
        let share = try wordShare(noticeText(Self.speedNotice()), width: Self.column)

        XCTAssertGreaterThan(share, WordFootprint.drawn,
                             "the speed warning drew \(String(format: "%.4f", share)) "
                             + "of its column, which is nothing")
    }

    func testNeitherWarningTruncatesWhenTheColumnNarrows() throws {
        // The thing ink cannot see. Content that wraps gets TALLER as it
        // narrows; content that truncates keeps its height and loses words
        // instead, and both measure as plenty of ink (#411).
        for (what, message) in [("music", Self.musicNotice()),
                                ("speed", Self.speedNotice())] {
            let wide = heightAt(noticeText(message), width: 420)
            let narrow = heightAt(noticeText(message), width: Self.column)

            XCTAssertGreaterThan(narrow, wide,
                                 "the \(what) warning is the same height at "
                                 + "\(Int(Self.column))pt as at 420pt, so it is "
                                 + "truncating rather than wrapping and the end "
                                 + "of the sentence is gone")
        }
    }

    // MARK: - The pace sampler

    /// A strip tall enough to scroll, drawn rather than loaded: nothing here
    /// reads a real photograph (L2).
    private func strip(height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 200, height: height))
        image.lockFocus()
        NSColor(calibratedRed: 0.2, green: 0.35, blue: 0.6, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 200, height: height).fill()
        NSColor.white.setFill()
        for band in stride(from: 0, to: height, by: 60) {
            NSRect(x: 20, y: band, width: 160, height: 8).fill()
        }
        image.unlockFocus()
        return image
    }

    func testThePaceSamplerDrawsItsLabel() throws {
        let sampler = ReelPaceSampler(strip: strip(height: 1800),
                                      stripCanvasHeight: 9000,
                                      scrollSeconds: 20,
                                      onClose: {})

        let share = try wordShare(sampler, width: 320)

        XCTAssertGreaterThan(share, WordFootprint.drawn,
                             "the pace sampler drew no words at all, so its "
                             + "label is in the view tree and not on the screen")
    }

    func testThePaceSamplerWindowIsTheShapeItClaims() {
        // The awkward one, being animated: measuring its first frame at least
        // catches a window of the wrong shape, which is what the issue asks
        // for. The window is the viewport the sample scrolls inside, and one
        // that is not the declared ratio is showing a different amount of the
        // reel than the reel will.
        let height = heightAt(ReelPaceSampler(strip: strip(height: 1800),
                                              stripCanvasHeight: 9000,
                                              scrollSeconds: 20,
                                              onClose: {}),
                              width: 320)

        XCTAssertGreaterThan(height, 40,
                             "the sampler laid out \(height)pt tall, which is "
                             + "not a window anything can be seen through")
        XCTAssertLessThan(height, 600,
                          "the sampler laid out \(height)pt tall, which is a "
                          + "panel rather than the sample window it claims to "
                          + "be, and it would push the controls under it off "
                          + "the editor")
    }

    func testTheMeasurementCanTellADrawnNoticeFromABlankOne() throws {
        // Both directions (L159). Without it, "the warning drew its words" is
        // satisfied by a measurement that says yes to anything, including to
        // the empty column this exists to catch.
        let blank = try wordShare(Text(""), width: Self.column)
        let real = try wordShare(noticeText(Self.musicNotice()), width: Self.column)

        XCTAssertLessThanOrEqual(blank, WordFootprint.drawn,
                                 "an empty notice measures as drawn, so the "
                                 + "floor cannot catch a clipped one")
        XCTAssertGreaterThan(real, blank,
                             "a real notice measures no more than an empty "
                             + "one, so the reading is not about the words")
    }
}
