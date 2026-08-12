import XCTest
import SwiftUI
import AppKit

/// #404: the two controls `BannerLegibilityTests` cannot draw.
///
/// `ImageRenderer` has no AppKit host, so `Menu` and `ProgressView` come out as a
/// bright placeholder block instead of themselves. That block is a colour unlike
/// the fill, so it MEASURES AS INK: a surface made of one and nothing else clears
/// every check over there while showing no words. Two things Dan interacts with
/// were therefore unverifiable, and one of them matters more than it sounds: the
/// spinner in the caption review bar is what stops him exporting a stale file.
///
/// These render through a real `NSHostingView` instead, which lays out and draws
/// the actual AppKit controls.
///
/// What that turned out to be worth is NOT more ink. A spinner that is not
/// animating draws so faintly that this metric reads it as blank, which is
/// measured below rather than assumed. The value is the LAYOUT: AppKit lays these
/// out the way the shipping app does, and the first render found the waiting bar
/// demanding 654pt at every width and truncating below it, which no amount of ink
/// counting would have shown.
@MainActor
final class HostedControlLegibilityTests: XCTestCase {

    /// Same threshold as the ImageRenderer harness, for the same reason: below the
    /// thinnest real surface and far above a blank page.
    private static let legibleInk = 0.01

    /// The narrowest detail pane a notice has to survive.
    ///
    /// The window opens at 1200pt with a sidebar of at least 230, so this is not
    /// the default case. It is the case Dan creates by dragging the window narrow
    /// to sit beside a browser, which is how he works: the program has to be
    /// downloaded from one. 520 leaves room for the sidebar inside a 785pt window.
    private static let narrowestPane: CGFloat = 520

    /// Renders through AppKit and returns the pixels.
    ///
    /// No window. An `NSHostingView` laid out and asked to cache its display draws
    /// its real controls without one, which keeps this runnable on a machine with
    /// no window server rather than making it a check that only works locally.
    private func render(_ view: some View,
                        width: CGFloat = 520,
                        height: CGFloat = 90) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: ZStack {
            Color.cream
            view.padding(Spacing.md)
        }.frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "AppKit produced no bitmap to draw into")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The share of pixels differing noticeably from the most common colour, which
    /// IS the background. Same measurement as the ImageRenderer harness.
    private func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
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

    /// The states that carry an unrenderable control, each built the way the app
    /// builds it.
    private var states: [(name: String, view: AnyView, height: CGFloat)] {
        [
            // The one-day menu on the generation done screen. Its label is the
            // only thing Dan reads before pressing it.
            ("regenerate one day menu", AnyView(GenerationDoneBody(
                eventName: "Spring Gala",
                headline: RunOutcomeNotice.headline(week: WeekGenerationResult(),
                                                    failedDayCount: 0),
                isUnqualifiedSuccess: true,
                regenerableDays: DayName.allCases.map {
                    GenerationRegenerableDay(id: $0.rawValue, label: $0.displayName)
                })), 420),
            // The bar that stops an export while a day is still rebuilding. Its
            // spinner is the part that says the wait is live rather than stuck.
            ("waiting on rebuild bar", AnyView(CaptionReviewActionBar(
                activity: .waitingOnRebuild(reason: ExportReadiness.blockedReason(
                    regeneratingDays: [.thursday, .wednesday]) ?? ""))), 90),
        ]
    }

    // MARK: - The measurement can tell the two apart

    /// Why ink is the wrong question for a spinner, measured rather than assumed.
    ///
    /// Two facts, both surprising, and recording them is the point:
    ///
    /// * Through `ImageRenderer` a bare `ProgressView` measures as plenty of ink,
    ///   because the placeholder block it substitutes is a solid colour. That is
    ///   the trap `BannerLegibilityTests` documents.
    /// * Through AppKit it measures as **almost nothing**, because a spinner that
    ///   is not animating is far too faint for this metric to see. How close to
    ///   nothing depends on the macOS version: 0.0000 on macOS 26, 0.0104 on the
    ///   older one CI runs, which is why the figure itself is printed and not
    ///   pinned.
    ///
    /// So neither renderer can tell anyone whether the spinner is visible, and no
    /// test in this file claims to.
    func testInkCannotJudgeASpinnerInEitherRenderer() throws {
        let hosted = inkCoverage(try render(ProgressView(), height: 40))

        let imageRendered: Double = try {
            let renderer = ImageRenderer(content: ZStack {
                Color.cream
                ProgressView().padding(Spacing.md)
            }.frame(width: 520, height: 40))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            return inkCoverage(try XCTUnwrap(NSBitmapImageRep(data: tiff)))
        }()

        print(String(format: "  ProgressView ink: AppKit %.4f, ImageRenderer %.4f",
                     hosted, imageRendered))

        // The RULE, not the reading. An earlier version of this pinned the hosted
        // figure below the legibility floor because that is what it measured on
        // one Mac; CI's older macOS draws the same static spinner at 0.0104 and it
        // went red for a reason that was never the point. Asserting an exact
        // rendering rather than the invariant behind it is the defect this whole
        // session has been about (L103).
        //
        // The invariant that actually holds: the placeholder is a solid block and
        // the real control is a few faint strokes, so the placeholder measures as
        // several times more ink while being the one that shows nothing.
        XCTAssertGreaterThan(imageRendered, hosted * 3, """
            A hosted ProgressView measured \(String(format: "%.4f", hosted)) and the \
            ImageRenderer placeholder \(String(format: "%.4f", imageRendered)). The \
            placeholder is meant to be far the bolder of the two, which is exactly \
            why it can pass a legibility check while drawing no words. If these have \
            converged, one of the two renderers has changed and the reasoning in this \
            file needs redoing.
            """)
        XCTAssertGreaterThan(imageRendered, Self.legibleInk, """
            An ImageRenderer ProgressView no longer measures as ink, which would mean \
            the placeholder trap BannerLegibilityTests works around has gone away and \
            the states it builds without their menus can have them back.
            """)
    }

    // MARK: - The states

    func testEveryHostedStateDrawsSomethingLegible() throws {
        for state in states {
            let coverage = inkCoverage(try render(state.view, height: state.height))
            XCTAssertGreaterThan(coverage, Self.legibleInk, """
                "\(state.name)" rendered almost nothing but its own background \
                (\(String(format: "%.4f", coverage))), so the control Dan is meant to \
                see is not on the page.
                """)
        }
    }

    // MARK: - Fits, rather than merely inks

    /// The width AppKit says this content requires.
    ///
    /// Unconstrained on purpose. A layout that can wrap reports the width it needs
    /// once wrapped; a layout that cannot reports the width of its longest line,
    /// and anything narrower than that is where the words start disappearing.
    private func requiredWidth(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// A notice has to WRAP when the window narrows, not truncate.
    ///
    /// This is what hosting through AppKit bought that ink coverage never could.
    /// Content that wraps gets taller as it narrows; content that truncates keeps
    /// the same height and loses words instead, and both measure as plenty of ink.
    ///
    /// The failure it caught: the waiting bar wanted 654pt whatever width it was
    /// given, so on a window narrower than about 920pt (a normal size beside a
    /// browser) it read "Waiting for the Wednesday and..." and the reason export
    /// was blocked went missing (#404, L79).
    ///
    /// The app's default window is 1200pt with a sidebar of at least 230, so 400pt
    /// is a deliberately harsh floor rather than the narrowest real case: a notice
    /// that survives it survives anything Dan can drag the window to.
    func testANoticeWrapsWhenTheWindowNarrowsRatherThanTruncating() throws {
        let bar = CaptionReviewActionBar(activity: .waitingOnRebuild(
            reason: ExportReadiness.blockedReason(
                regeneratingDays: [.thursday, .wednesday]) ?? ""))

        let needed = requiredWidth(bar)
        print(String(format: "  waiting bar requires %.0fpt", needed))

        XCTAssertLessThanOrEqual(needed, Self.narrowestPane, """
            The waiting bar requires \(Int(needed))pt of width. The detail pane is \
            narrower than that whenever the window is under about \
            \(Int(needed) + 265)pt, and there the words at the end of its sentences \
            are simply gone. Let the text wrap instead of sitting on one line.
            """)
    }

    func testEveryHostedStateStillDrawsWhenNarrow() throws {
        for state in states {
            let coverage = inkCoverage(try render(state.view, width: 300,
                                                 height: state.height))
            XCTAssertGreaterThan(coverage, Self.legibleInk,
                                 "\"\(state.name)\" lost its content at 300pt wide")
        }
    }
}

#if POSTROLL_TESTS
extension HostedControlLegibilityTests {
    /// Writes the hosted states to PNG so a person can look at them, which is the
    /// point of the whole exercise.
    ///
    /// Asserts rather than merely producing files: a utility in the suite that
    /// cannot fail is indistinguishable from one that silently stopped working.
    func testDumpHostedStatesForReview() throws {
        let out = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["POSTROLL_HOSTED_DUMP"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("postroll-hosted").path)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for state in states {
            let rep = try render(state.view, height: state.height)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent(
                state.name.replacingOccurrences(of: " ", with: "-") + ".png"))
        }

        let written = try FileManager.default.contentsOfDirectory(atPath: out.path)
            .filter { $0.hasSuffix(".png") }
        XCTAssertEqual(written.count, states.count,
                       "every state has to reach disk, or reviewing these images is a "
                       + "review of whichever ones happened to be written")
    }
}
#endif
