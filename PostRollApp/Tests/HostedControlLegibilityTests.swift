import XCTest
import SwiftUI
import AppKit

/// One row of the sidebar, assembled the way `EventListView` assembles it
/// (#592): the shipping row, over the shipping background, with the insets the
/// list gives it.
///
/// A view rather than an expression in the test because the background needs a
/// `Namespace` and the hover object, which is what the list holds for it. Both
/// halves are the app's own, so a change to either moves what is measured here
/// rather than leaving this drawing a picture of a list that has moved on.
@MainActor
private struct EventListRowPreview: View {
    let event: Event
    let isSelected: Bool

    @Namespace private var selectionNamespace
    /// Nobody is pointing at a rendered row, which is the state every row but
    /// one is in at any moment.
    private let hover = EventListHover()

    /// The row with its words, or the same row's chrome with nothing in it.
    ///
    /// One view drawing both, so what the words are measured against is this
    /// row's own background rather than a second copy of it built here (L70).
    var wordless = false

    var body: some View {
        EventRow(event: event, isSelected: isSelected, renameText: .constant(""))
            .opacity(wordless ? 0 : 1)
            .padding(.horizontal, Spacing.rowInset)
            .padding(.vertical, Spacing.rowV)
            .background(EventRowBackground(eventID: event.id,
                                           isSelected: isSelected,
                                           hover: hover,
                                           selectionNamespace: selectionNamespace))
    }
}

/// Draws no type at all (#612).
///
/// The generic way to ask a shipping view what its words are worth. #607 could
/// put a `wordless` flag on the reading screen because that screen was being
/// written; the thirty-eight surfaces measured next door are shipping notices
/// that know nothing about being measured, and a flag on each of them would be
/// a change to the app for the benefit of a test.
///
/// Layout is untouched, because only the drawing is replaced: every fill,
/// border, symbol and button stays exactly where it was, so the difference
/// between a render with this and one without is the type and nothing else.
///
/// Applied to ONE side of the comparison only. Putting a renderer of ours on
/// the words-on side too changes the path the type takes, and that path is the
/// subject: the busy pill, whose label ImageRenderer is known to drop, drew its
/// label perfectly through a custom renderer.
private struct WordSwitch: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {}
}

/// #404: the two controls `BannerLegibilityTests` cannot draw.
///
/// `ImageRenderer` has no AppKit host, so `Menu` and `ProgressView` come out as a
/// bright placeholder block instead of themselves. That block is a colour unlike
/// the fill, so it MEASURES AS INK: a surface made of one and nothing else clears
/// every check over there while showing no words. Two things Dan interacts with
/// were therefore unverifiable, and one of them matters more than it sounds: the
/// spinner in the caption review bar is what stops him exporting a stale file.
///
/// A third thing it cannot draw turned up here (#592): the TEXT of any view
/// carrying a repeating animation. The stage pill starts one in `onAppear` while
/// a run is in flight, and through `ImageRenderer` the four busy pills come out
/// as an empty capsule with the pulsing dot and no word on it, while the same
/// pill hosted through AppKit reads "Generating…" perfectly. Measured both ways
/// below, because the difference is a property of the renderers and not of the
/// app.
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

    // MARK: - The event list, drawn at last (#592)

    /// A show a week out, with a program uploaded and nothing generated yet.
    ///
    /// A pinned date rather than `Date()`: this row is rendered and measured,
    /// and a fixture whose date moves with the clock is a picture of a
    /// different row every day (L130).
    private var sampleEvent: Event {
        Event(name: "Spring Gala", org: "City Ballet", venue: "City Center",
              date: Date(timeIntervalSince1970: 1_775_000_000), shootType: .fullShow)
    }

    /// The widths the sidebar can actually be, from the one place that sets
    /// them (`MainWindowView` opens the column at min 230, ideal 265). A row
    /// measured at the 520pt a detail pane gets would be a picture of a
    /// column this app never draws.
    private static let sidebarWidths: [(name: String, width: CGFloat)] =
        [("at its narrowest", 230), ("at its usual width", 265)]

    /// One row, at a column width, on the background the list gives it.
    ///
    /// Not through `render` above: that one puts the view on a cream page with
    /// a margin around it, which is what a notice in the detail pane sits on
    /// and is nothing like a sidebar row. The list's background is `deepPage`
    /// and the row fills the column, so a cream margin here would be a colour
    /// the screen does not have, and on a selected row it differs from the
    /// selection fill by just over the threshold, which put a band of it into
    /// the measurement as though it were type.
    private func renderRow(isSelected: Bool,
                           width: CGFloat,
                           wordless: Bool) throws -> NSBitmapImageRep {
        let row = EventListRowPreview(event: sampleEvent,
                                      isSelected: isSelected,
                                      wordless: wordless)
            .environment(GenerationManager())
            .environment(OCRManager())
            .environment(ExportManager())
            .background(PaintedSurfaces.deepPage)
            .frame(width: width)

        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.height, 30,
                             "the row laid out \(host.frame.height)pt tall, which is "
                             + "not a row; the measurement would be of nothing")
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "AppKit produced no bitmap for the row")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// One row of the list, drawn.
    ///
    /// The whole point of #592: `PaintedSurfaces` holds every colour on this
    /// row against the colour behind it, and a ratio cannot see a word that is
    /// clipped, drawn behind something else, or not on the page at all. This is
    /// the screen Dan spends the most time on and nothing had ever rendered it.
    ///
    /// Measured against the SAME ROW WITH NO WORDS IN IT, not against a fixed
    /// floor. A selected row paints a rose gold spine and a warm fill of its
    /// own, and those are marks on the page whatever the type does: the first
    /// version of this used the flat threshold and a row with every word
    /// switched off still cleared it on its spine alone, which is L141 in the
    /// one place this file exists to catch it.
    func testTheEventRowDrawsItsWordsAtEveryWidthTheSidebarHas() throws {
        for (where_, width) in Self.sidebarWidths {
            for isSelected in [false, true] {
                let state = isSelected ? "selected" : "at rest"

                let words = inkCoverage(try renderRow(isSelected: isSelected,
                                                     width: width, wordless: false))
                let chrome = inkCoverage(try renderRow(isSelected: isSelected,
                                                       width: width, wordless: true))
                print(String(format: "  %.4f words, %.4f chrome   row %@, %@",
                             words, chrome, state, where_))

                XCTAssertGreaterThan(words, Self.legibleInk, """
                    A row \(state), \(where_) (\(Int(width))pt), rendered almost \
                    nothing but its own background \
                    (\(String(format: "%.4f", words))). The name, the organisation, \
                    the date and the stage are in the view tree and are not on the \
                    screen.
                    """)
                XCTAssertGreaterThan(words, chrome * 3, """
                    A row \(state), \(where_), measures \
                    \(String(format: "%.4f", words)) with its words and \
                    \(String(format: "%.4f", chrome)) with every one of them switched \
                    off. The words have to be worth far more ink than the fill and \
                    the spine the row paints for itself, or this check is reading the \
                    decoration and would pass on a row showing nothing.
                    """)
            }
        }
    }

    /// One pill, at its own size, on the row behind it.
    ///
    /// No page around it: the image IS the pill, so the only things that can put
    /// ink on its wash are its label and its busy dot. Measured inside a whole
    /// row instead, a pill is a few dozen pixels of a page full of type and a
    /// label that stopped drawing would move the number by less than the
    /// difference between one stage's wording and another's.
    private func renderPill(_ state: StagePillState,
                            isSelected: Bool) throws -> NSBitmapImageRep {
        let row = isSelected ? PaintedSurfaces.eventRowSelected
                             : PaintedSurfaces.eventRowAtRest
        let host = NSHostingView(rootView: StagePill(state: state, isSelected: isSelected)
            .background(row))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.width, 20,
                             "the \(state) pill laid out at \(host.frame.width)pt wide, "
                             + "which is not a pill; the measurement below would be of "
                             + "nothing")
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "AppKit produced no bitmap for the \(state) pill")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Every state the pill can be in, drawn, on both of the rows it sits on.
    ///
    /// Per state rather than one sample of the family, for the reason the pair
    /// walk is: each state is its own wording on its own wash. Taken from
    /// `allPillStates` rather than a list here, so an eighth stage cannot
    /// arrive with nobody drawing it (L113).
    func testEveryStagePillDrawsItsLabel() throws {
        var measured: [(String, Double)] = []
        for state in StagePillState.allPillStates {
            for isSelected in [false, true] {
                let where_ = isSelected ? "selected" : "at rest"
                let coverage = inkCoverage(try renderPill(state, isSelected: isSelected))
                measured.append(("\(state), row \(where_)", coverage))

                XCTAssertGreaterThan(coverage, Self.legibleInk, """
                    The \(state) pill on a row \(where_) rendered almost nothing but \
                    its own wash (\(String(format: "%.4f", coverage)) of pixels \
                    differ), so its label is in the view tree and not on the screen.
                    """)
            }
        }
        for (name, coverage) in measured.sorted(by: { $0.1 < $1.1 }) {
            print(String(format: "  %.4f  %@", coverage, name))
        }
    }

    /// The pill measurement can fail, or the walk above is decoration (L1).
    ///
    /// A capsule whose label is drawn in its own wash is the defect in bare
    /// form, and it is the one the ratio walk exists for. Proving the picture
    /// can see it too is what makes the two checks independent rather than one
    /// check counted twice.
    func testThePillMeasurementTellsALabelFromAnEmptyCapsule() throws {
        let pill = PaintedSurfaces.stagePill(.awaitingExport)
        func capsule(_ ink: Color) -> some View {
            Text(StagePillState.awaitingExport.label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(pill.wash)
                .foregroundStyle(ink)
                .clipShape(Capsule())
                .background(PaintedSurfaces.eventRowAtRest)
        }

        let invisible = inkCoverage(try hostedAtItsOwnSize(capsule(
            pill.wash.composited(over: PaintedSurfaces.eventRowAtRest))))
        let legible = inkCoverage(try hostedAtItsOwnSize(capsule(pill.ink)))

        XCTAssertLessThan(invisible, Self.legibleInk, """
            A pill label drawn in the colour of its own wash measured \
            \(String(format: "%.4f", invisible)), above the threshold the walk above \
            uses, so that walk would pass on a pill showing no words.
            """)
        XCTAssertGreaterThan(legible, invisible * 10,
                             "the same label in its real ink has to measure as far more "
                             + "ink, or the pill render is not reading the type at all")
    }

    /// What ImageRenderer does to a view that is animating, measured (#592).
    ///
    /// The stage pill starts a `repeatForever` pulse in `onAppear` while a run
    /// is in flight. Through `ImageRenderer` that pill loses its LABEL: the
    /// capsule and the pulsing dot are drawn and the word is not, which is why
    /// the pills are rendered in this file rather than beside the notices.
    ///
    /// Recorded as a measurement rather than a note, for the reason
    /// `testInkCannotJudgeASpinnerInEitherRenderer` is: if the renderer ever
    /// learns to draw these, the reasoning here needs redoing, and nothing else
    /// would say so.
    func testImageRendererLosesTheLabelOfAnAnimatingPill() throws {
        let hosted = inkCoverage(try renderPill(.generating, isSelected: false))

        let imageRendered: Double = try {
            let renderer = ImageRenderer(content: ZStack {
                PaintedSurfaces.eventRowAtRest
                StagePill(state: .generating)
            })
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            return inkCoverage(try XCTUnwrap(NSBitmapImageRep(data: tiff)))
        }()

        print(String(format: "  busy pill ink: AppKit %.4f, ImageRenderer %.4f",
                     hosted, imageRendered))

        XCTAssertGreaterThan(hosted, imageRendered * 3, """
            A hosted busy pill measured \(String(format: "%.4f", hosted)) and the same \
            pill through ImageRenderer \(String(format: "%.4f", imageRendered)). The \
            hosted one is meant to be far the bolder, because ImageRenderer draws the \
            capsule and the dot and drops the word. If these have converged, \
            ImageRenderer has learned to draw an animating view and the pills can be \
            measured beside the notices again.
            """)
        XCTAssertGreaterThan(hosted, Self.legibleInk,
                             "the hosted busy pill has to draw its label, or this "
                             + "comparison is between two blank images")
    }

    /// A view rendered at exactly the size it asks for.
    private func hostedAtItsOwnSize(_ view: some View) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - The screen a program is read on (#607)

    /// What the reading screen says, from the code that says it.
    ///
    /// Nothing here is typed copy. The phase comes from `OCRProgressText.phase`
    /// over a step the run could really write, the footer from
    /// `OCRProgressText.footer` over a real `LongRunStatus`, and the timer from
    /// the app's own formatter, so this draws the screen the app shows rather
    /// than one invented beside it (L48).
    ///
    /// A pinned `updatedAt` rather than the clock: the step is half of a pair
    /// whose meaning is its distance from now, and leaving the other half live
    /// walks the fixture into a state nobody chose (L130). The status is stated
    /// outright for the same reason, instead of being derived from a threshold
    /// against the moment the test happens to run.
    private static var readingStates: [(name: String, live: OCRProgressBody.Live)] {
        let step = GenerationStep(label: "Reading the program", index: 2, total: 3,
                                  updatedAt: 1_760_000_000)
        let estimate: Double = 95

        func live(_ status: LongRunStatus, step: GenerationStep?,
                  seconds: Int) -> OCRProgressBody.Live {
            OCRProgressBody.Live(
                phase: OCRProgressText.phase(
                    step: step,
                    fallback: OCRProgressText.elapsedPhase(elapsedSeconds: seconds,
                                                           estimate: estimate)),
                elapsedText: OCRProgressText.elapsed(seconds: seconds),
                footer: OCRProgressText.footer(
                    status: status, estimate: estimate,
                    formattedEstimate: TimingStore.formatEstimate(estimate)))
        }

        return [
            ("before the run has reported anything",
             live(.working(elapsedSeconds: 4, step: nil), step: nil, seconds: 4)),
            ("part way through",
             live(.working(elapsedSeconds: 67, step: step), step: step, seconds: 67)),
            ("gone quiet",
             live(.stalled(elapsedSeconds: 900, step: step), step: step, seconds: 900)),
        ]
    }

    /// The reading screen at the size the detail pane gives it.
    ///
    /// Hosted rather than image-rendered, and that is the whole reason this
    /// lives in this file: the shimmer rail runs a `repeatForever` animation,
    /// and #592 measured what `ImageRenderer` does to a view carrying one. It
    /// draws the shape and drops the TEXT, so added to the harness next door
    /// this screen would have passed while showing no words at all.
    private func renderReadingScreen(_ live: OCRProgressBody.Live,
                                     wordless: Bool,
                                     width: CGFloat = 520) throws -> NSBitmapImageRep {
        let view = OCRProgressBody(eventName: "Spring Gala",
                                   live: { _ in live },
                                   onCancel: {},
                                   wordless: wordless)
            .frame(width: width, height: 400)
            .background(PaintedSurfaces.page)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "AppKit produced no bitmap for the reading screen")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// A lower floor than the 0.01 the rest of this file uses, and the reason is
    /// the surface rather than a weaker standard.
    ///
    /// This is a whole detail pane holding a name, two short lines, a timer and
    /// a footer, centred in a great deal of empty page, where a notice is a
    /// small box that is almost all type. Measured, the three states render
    /// between 0.0138 and 0.0256, and the same screen with every word switched
    /// off renders 0.0007. So this sits comfortably between drawn and blank,
    /// and the ratio below is what makes either number mean anything. The same
    /// call `PhotoLightboxTests` made, for the same shape of screen.
    private static let readingScreenInk = 0.005

    /// The screen Dan watches for minutes while a program is read, drawn (#607).
    ///
    /// Every notice, every stage pill and the whole event list are rendered and
    /// measured, and this one never was, so nothing had ever confirmed its
    /// words reach the screen.
    ///
    /// Measured against the SAME SCREEN WITH ITS WORDS SWITCHED OFF rather than
    /// a flat threshold. The shimmer rail is a mark on the page whatever the
    /// type does, and a floor alone would let it answer for the type (L141).
    /// What that comparison establishes here is that the rail is worth 0.0007
    /// and could not have answered for it, which is a measurement rather than
    /// the assumption it replaced.
    func testTheReadingScreenDrawsItsWords() throws {
        for state in Self.readingStates {
            let words = inkCoverage(try renderReadingScreen(state.live, wordless: false))
            let chrome = inkCoverage(try renderReadingScreen(state.live, wordless: true))
            print(String(format: "  %.4f words, %.4f shimmer only   reading, %@",
                         words, chrome, state.name))

            XCTAssertGreaterThan(words, Self.readingScreenInk, """
                The reading screen "\(state.name)" rendered almost nothing but its own \
                page (\(String(format: "%.4f", words))). The show's name, the phase, \
                the timer and the footer are in the view tree and are not on the \
                screen, which is the state Dan sits in front of for minutes at a time.
                """)
            XCTAssertGreaterThan(words, chrome * 3, """
                The reading screen "\(state.name)" measures \
                \(String(format: "%.4f", words)) with its words and \
                \(String(format: "%.4f", chrome)) with every one of them switched off. \
                The words have to be worth far more ink than the shimmer rail the \
                screen paints for itself, or this check is reading the decoration and \
                would pass on a screen showing nothing (L141).
                """)
        }
    }

    /// The screen still draws when the window is dragged narrow.
    func testTheReadingScreenStillDrawsWhenNarrow() throws {
        for state in Self.readingStates {
            let coverage = inkCoverage(try renderReadingScreen(state.live,
                                                               wordless: false,
                                                               width: 300))
            XCTAssertGreaterThan(coverage, Self.readingScreenInk,
                                 "the reading screen \"\(state.name)\" lost its content "
                                 + "at 300pt wide")
        }
    }

    /// Where the animation trap actually reaches, measured rather than assumed.
    ///
    /// #607 was filed expecting this screen to be the stage pill's case again:
    /// it carries a `repeatForever` shimmer, and #592 measured `ImageRenderer`
    /// drawing an animating pill's capsule and dropping its word. Through
    /// `ImageRenderer` this screen measures 0.0111 with its words and 0.0003
    /// without them, so the words are drawn.
    ///
    /// #607 read that as a property of the screen, and said the difference was
    /// WHERE the animation is declared: `StagePill` starts its pulse in an
    /// `onAppear` on the pill so the transaction covers the label, while
    /// `OCRShimmerLine` starts its own inside itself. That is wrong, and #612
    /// measured it: rendered at its own size this screen loses every word it
    /// has, exactly like the pill. What decides it is whether the renderer is
    /// given a SIZE, and this check gives it one on the line above.
    ///
    /// So what it holds is narrower than it was thought to hold, and still
    /// worth having: this screen, drawn the way the harness draws it, puts its
    /// words on the page. `testTheRendererDrawsAnimatingWordsOnlyWhenItIsGivenASize`
    /// is where the mechanism itself is pinned.
    func testTheAnimationTrapHasNotReachedThisScreensWords() throws {
        let live = try XCTUnwrap(Self.readingStates.first).live

        func imageRendered(wordless: Bool) throws -> Double {
            let renderer = ImageRenderer(content: OCRProgressBody(
                eventName: "Spring Gala", live: { _ in live }, onCancel: {},
                wordless: wordless)
                .frame(width: 520, height: 400)
                .background(PaintedSurfaces.page))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            return inkCoverage(try XCTUnwrap(NSBitmapImageRep(data: tiff)))
        }

        let words = try imageRendered(wordless: false)
        let chrome = try imageRendered(wordless: true)
        print(String(format: "  reading screen through ImageRenderer: %.4f words, "
                     + "%.4f shimmer only", words, chrome))

        XCTAssertGreaterThan(words, chrome * 3, """
            Through ImageRenderer the reading screen measures \
            \(String(format: "%.4f", words)) with its words and \
            \(String(format: "%.4f", chrome)) with them switched off, which means the \
            words are no longer being drawn. #592's animation trap has reached this \
            screen: something has moved the shimmer's repeating animation up to a view \
            the type sits under. The hosted checks above still see it, so nothing is \
            unguarded, but any surface added to BannerLegibilityTests near this one is \
            now measuring its own decoration.
            """)
    }

    // MARK: - The screen a read fails on (#613)

    /// What the failure screen says, from the code that says it.
    ///
    /// Every message is a real `PythonBridgeError` rendered through its own
    /// `localizedDescription`, which is the exact route `OCRManager` takes when
    /// a run dies: it catches an error and stores that string. Nothing here is
    /// typed copy, so a fixture cannot show a sentence the app never says
    /// (L48).
    ///
    /// Three lengths, because the message is the one part of this screen whose
    /// size the app does not control: a stopped run says one sentence, an
    /// unrecognised failure says three and quotes the log.
    private static var failureMessages: [(name: String, message: String)] {
        [
            ("a run that timed out",
             PythonBridgeError.timedOut(seconds: 600).localizedDescription),
            ("a read that produced nothing",
             PythonBridgeError.outputMissing.localizedDescription),
            ("a failure nothing recognised",
             PythonBridgeError.scriptFailed(
                exitCode: 1,
                stderr: "Traceback (most recent call last):\n"
                    + "  File \"postroll/ai/ocr.py\", line 214, in read_program\n"
                    + "RuntimeError: the page bundle was rejected by the service")
                .localizedDescription),
        ]
    }

    private func renderFailureScreen(_ message: String,
                                     hiding: Set<OCRFailureBody.Part> = [],
                                     width: CGFloat = 520) throws -> NSBitmapImageRep {
        let view = OCRFailureBody(message: message, onRetry: {}, onGoBack: {},
                                  hidden: hiding)
            .frame(width: width, height: 400)
            .background(PaintedSurfaces.page)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "AppKit produced no bitmap for the failure screen")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The share of pixels one part of a screen accounts for.
    ///
    /// Two renders of the same view at the same size, differing only in whether
    /// that part is drawn, compared pixel for pixel. Ink over the whole surface
    /// cannot answer this: a 44pt symbol and a filled button are marks on the
    /// page whatever the type does, and the guard that measured a filled button
    /// that way read 0.2475 of it as content while almost all of it was the
    /// button's own background (#559, L141). A difference isolates the part.
    ///
    /// Layout is identical between the two, because a part is switched off with
    /// `.opacity(0)` rather than removed, so a pixel that moved is a pixel that
    /// part drew.
    private func footprint(_ whole: NSBitmapImageRep,
                           _ without: NSBitmapImageRep) -> Double {
        guard whole.pixelsWide == without.pixelsWide,
              whole.pixelsHigh == without.pixelsHigh else { return 0 }
        var differing = 0
        var sampled = 0
        for y in Swift.stride(from: 0, to: whole.pixelsHigh, by: 2) {
            for x in Swift.stride(from: 0, to: whole.pixelsWide, by: 2) {
                guard let a = whole.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = without.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                sampled += 1
                func luminance(_ c: NSColor) -> Double {
                    0.299 * c.redComponent + 0.587 * c.greenComponent
                        + 0.114 * c.blueComponent
                }
                if abs(luminance(a) - luminance(b)) > 0.02 { differing += 1 }
            }
        }
        guard sampled > 0 else { return 0 }
        return Double(differing) / Double(sampled)
    }

    /// What a part, or a whole surface's type, has to be worth to count as
    /// drawn.
    ///
    /// Not a share of the surface picked to sit under whatever the smallest one
    /// measured. Two renders of the SAME view differ by nothing at all, which
    /// `testTheFootprintOfNothingIsNothing` measures rather than assumes, so
    /// anything above zero is type putting pixels on the page. This is a margin
    /// over that zero, and both bands it is judged against sit well clear of
    /// it: the smallest part of the failure screen, the 11pt Go Back, is 0.0013,
    /// and the thirty-eight measured notices run from 0.0097 to 0.0761 (#612).
    ///
    /// The other side of it is measured too. A surface whose words the renderer
    /// drops reads 0.0000, not merely small, because the two renders are then
    /// the same image.
    private static let drawnFootprint = 0.0004

    /// Every word on the screen a read fails on reaches the screen (#613).
    ///
    /// The failure half of the view #607 drew. It is the only screen that says
    /// a paid read did not work, and the only place the way to run it again is
    /// offered, and nothing had ever rendered it.
    ///
    /// Per part rather than per screen, because a screen check here would be
    /// answered by the symbol and the button fill: those two are most of the
    /// ink, so the heading and the reason could both vanish and a whole-surface
    /// measurement would barely move (L141).
    func testTheFailureScreenDrawsEveryOneOfItsWords() throws {
        for state in Self.failureMessages {
            let whole = try renderFailureScreen(state.message)
            for part in OCRFailureBody.Part.allCases {
                let without = try renderFailureScreen(state.message, hiding: [part])
                let share = footprint(whole, without)
                print(String(format: "  %.4f  %@, %@", share, state.name, part.rawValue))

                XCTAssertGreaterThan(share, Self.drawnFootprint, """
                    On the failure screen for \(state.name), switching "\(part.rawValue)" \
                    off changed \(String(format: "%.4f", share)) of the render, which is \
                    nothing. That part is in the view tree and not on the screen: this is \
                    the screen that tells Dan a paid read did not work and offers the way \
                    to run it again.
                    """)
            }
        }
    }

    /// The failure screen still says everything when the window is narrow.
    func testTheFailureScreenDrawsEveryWordWhenNarrow() throws {
        let message = try XCTUnwrap(Self.failureMessages.last).message
        let whole = try renderFailureScreen(message, width: Self.narrowestPane)
        for part in OCRFailureBody.Part.allCases {
            let without = try renderFailureScreen(message, hiding: [part],
                                                  width: Self.narrowestPane)
            XCTAssertGreaterThan(footprint(whole, without), Self.drawnFootprint,
                                 "the failure screen lost \"\(part.rawValue)\" at "
                                 + "\(Int(Self.narrowestPane))pt wide")
        }
    }

    /// The measurement's own zero, measured rather than assumed (L1).
    ///
    /// The floor above is a margin over "no difference at all". If two renders
    /// of the same view ever stopped agreeing, every figure in these checks
    /// would be noise and the floor would be measuring the renderer.
    func testTheFootprintOfNothingIsNothing() throws {
        let message = try XCTUnwrap(Self.failureMessages.first).message
        let once = try renderFailureScreen(message)
        let again = try renderFailureScreen(message)
        XCTAssertEqual(footprint(once, again), 0, accuracy: 0.00001, """
            two renders of the same screen differ, so the footprint measurement is \
            reading the renderer rather than the words and the floor it is judged \
            against means nothing
            """)
    }

    /// The measurement can tell a part that drew from one that did not (L1).
    ///
    /// The same proof `BannerLegibilityTests` gets for ink: one view, rendered
    /// twice, differing only in whether its type is the colour of the page
    /// behind it. Type drawn in its own background is the defect this whole
    /// harness exists for, and it has shipped in this app three times.
    func testTheFootprintTellsDrawnTypeFromInvisibleType() throws {
        func card(_ colour: Color) -> some View {
            ZStack {
                PaintedSurfaces.page
                Text("The program could not be read.")
                    .font(.system(size: 12))
                    .foregroundStyle(colour)
            }
            .frame(width: 520, height: 90)
        }

        let blank = try render(ZStack { PaintedSurfaces.page }.frame(width: 520,
                                                                     height: 90))
        let invisible = footprint(try render(card(PaintedSurfaces.page)), blank)
        let legible = footprint(try render(card(Color.warmDark)), blank)

        XCTAssertLessThan(invisible, Self.drawnFootprint, """
            type drawn in the colour of the page behind it measures \
            \(String(format: "%.4f", invisible)) as a footprint, which clears the floor \
            the checks above use, so those checks would pass on a screen showing nothing
            """)
        XCTAssertGreaterThan(legible, Self.drawnFootprint * 5, """
            the same sentence in a readable colour measures \
            \(String(format: "%.4f", legible)), which is not far enough above the floor \
            for the floor to mean anything
            """)
    }

    // MARK: - Every measured state, asked what its words are worth (#612)
    //
    // The thirty-eight surfaces measured next door had never been asked. A
    // surface whose type does not reach the page measures its own fill, border
    // and button while reporting a pass, which is what #404, #559 and #592 were
    // each about, and no threshold over there can say so: the state renders,
    // the number is respectable, and the words are missing.
    //
    // So each state is drawn twice, once as the harness draws it and once with
    // its words switched off, and the two images are compared pixel for pixel.
    // The difference is the type.
    //
    // The answer for the animation trap specifically is that it cannot reach
    // these states while the harness renders into a frame, which is measured in
    // the two checks above rather than assumed. What this sweep is for is the
    // general case: type that does not draw, for any reason.

    /// One view through ImageRenderer, exactly as the notice harness draws it,
    /// or with its words switched off.
    ///
    /// The words-on render carries NO modifier of any kind. That is not a
    /// detail: the first version of this asked for both renders through a
    /// custom text renderer, and putting one on the words-on side dissolved the
    /// defect being looked for. The busy pill, which ImageRenderer is known to
    /// draw without its label, came out WITH its label as soon as its type went
    /// through a renderer of ours, so the check measured a screen the harness
    /// does not draw and reported everything healthy. The calibration below is
    /// the only reason that was ever noticed (L1).
    private func imageRendered(_ content: some View,
                               wordless: Bool) throws -> NSBitmapImageRep {
        let renderer = wordless
            ? ImageRenderer(content: AnyView(content.textRenderer(WordSwitch())))
            : ImageRenderer(content: AnyView(content))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the state produced no image at all")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    /// What the words of one surface are worth, drawn the way the notice
    /// harness draws it.
    private func wordFootprint(of view: some View, width: CGFloat = 520) throws -> Double {
        let content = ZStack {
            PaintedSurfaces.page
            view.padding(Spacing.md)
        }.frame(width: width)

        return footprint(try imageRendered(content, wordless: false),
                         try imageRendered(content, wordless: true))
    }

    /// Every measured surface is one the renderer can actually see (#612).
    ///
    /// Measured as a difference rather than as a ratio of ink. Ink is the share
    /// of pixels unlike the commonest colour, and on a surface that is mostly
    /// its own button fill, removing the type MOVES what the commonest colour
    /// is: three of these states measured MORE ink with their words switched
    /// off than with them on. A metric that can go up when content is taken
    /// away cannot be asked whether content is there. The difference between
    /// the two images can: it is the type, and nothing else.
    func testNoMeasuredStateIsInvisibleToTheRendererThatMeasuresIt() throws {
        let states = BannerLegibilityTests.measuredStates

        // A sweep that reads nothing objects to nothing (L98).
        XCTAssertGreaterThan(states.count, 30,
                             "the sweep found \(states.count) measured states, so it is "
                             + "proving nothing about the ones it did not draw")

        var measured: [(String, Double)] = []
        for state in states {
            let share = try wordFootprint(of: state.view)
            measured.append((state.name, share))

            XCTAssertGreaterThan(share, Self.drawnFootprint, """
                Switching every word off "\(state.name)" changed \
                \(String(format: "%.4f", share)) of the render, which is nothing. Its \
                type is not reaching the page, so what the notice harness measures over \
                there is the fill, the border and the button: it would report the same \
                number with the surface empty (L141). Either the words are drawn in the \
                colour of what is behind them, or ImageRenderer is not drawing them at \
                all, in which case the state belongs in this file where AppKit hosts it.
                """)
        }

        for (name, share) in measured.sorted(by: { $0.1 < $1.1 }) {
            print(String(format: "  %.4f  %@", share, name))
        }
    }

    /// What actually decides whether ImageRenderer draws an animating view's
    /// words, measured (#612).
    ///
    /// This is a correction. #592 found the busy stage pill coming out of
    /// ImageRenderer as a capsule and a dot with no label, and #607 concluded
    /// the difference was WHERE the animation is declared: the pill starts its
    /// pulse on the pill, so the transaction covers the label, while
    /// `OCRShimmerLine` starts its own inside itself and the type in a sibling
    /// survives. That explanation fits both observations and is wrong.
    ///
    /// What decides it is whether the renderer is given a SIZE. Measured here
    /// on both views:
    ///
    /// * the busy pill at its own size loses its word, and at a proposed width
    ///   keeps it;
    /// * the reading screen at its own size loses EVERY word it has, and at a
    ///   proposed size keeps them all.
    ///
    /// So the screen #607 measured as safe is not safe by construction; it is
    /// safe because that check renders it into a frame. The two views differ in
    /// nothing that matters here.
    ///
    /// Both halves are asserted rather than printed. The half that loses its
    /// words is what proves the footprint measurement can see the defect at all
    /// (L1), and the half that keeps them is what the whole sweep below rests
    /// on: the notice harness always proposes a width, which is why none of its
    /// thirty-eight surfaces can be hit by this.
    func testTheRendererDrawsAnimatingWordsOnlyWhenItIsGivenASize() throws {
        func share(_ content: some View) throws -> Double {
            footprint(try imageRendered(content, wordless: false),
                      try imageRendered(content, wordless: true))
        }

        let pill = ZStack {
            PaintedSurfaces.eventRowAtRest
            StagePill(state: .generating)
        }
        let live = try XCTUnwrap(Self.readingStates.first).live
        let readingScreen = OCRProgressBody(eventName: "Spring Gala",
                                            live: { _ in live }, onCancel: {})
            .background(PaintedSurfaces.page)

        let cases: [(name: String, ownSize: Double, sized: Double)] = [
            ("the busy stage pill",
             try share(pill), try share(pill.frame(width: 520))),
            ("the reading screen",
             try share(readingScreen),
             try share(readingScreen.frame(width: 520, height: 400))),
        ]

        for one in cases {
            print(String(format: "  %@: %.4f at its own size, %.4f given one",
                         one.name, one.ownSize, one.sized))

            XCTAssertLessThan(one.ownSize, Self.drawnFootprint, """
                Switching the words off \(one.name) rendered at its own size changed \
                \(String(format: "%.4f", one.ownSize)) of the image, which means the \
                words were there to lose. ImageRenderer has learned to draw an animating \
                view unsized, and the reasoning in this file, in #592 and in #607 needs \
                redoing: the sweep below is calibrated on this being the case that fails.
                """)
            XCTAssertGreaterThan(one.sized, Self.drawnFootprint, """
                \(one.name) given a size lost its words too \
                (\(String(format: "%.4f", one.sized))). Every check in the notice harness \
                renders into a frame, so if a proposed size no longer restores the words, \
                thirty-eight surfaces over there are measuring their own fills and \
                borders and reporting a pass.
                """)
        }
    }

    /// The notice harness gives the renderer a size (#612).
    ///
    /// The sweep below is only true while that holds. It is one line in the
    /// helper every check over there renders through, and nothing else would
    /// say if it went: the states would keep rendering, the ink would still be
    /// mostly fills and borders, and every threshold would still pass.
    ///
    /// Scoped to that one function rather than searched for over the file,
    /// because the file mentions widths in a dozen places and a match anywhere
    /// in it would answer for the region this is about (L135).
    func testTheNoticeHarnessRendersIntoAFrame() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("BannerLegibilityTests.swift")
        let code = SwiftSourceText.withoutComments(
            try String(contentsOf: url, encoding: .utf8))

        let start = try XCTUnwrap(code.range(of: "private func render("),
                                  "BannerLegibilityTests no longer has a render helper, "
                                  + "so this check is reading a file that has moved on")
        let body = code[start.lowerBound...]
        let end = try XCTUnwrap(body.range(of: "\n    }"),
                                "the render helper never closes, so this is reading the "
                                + "rest of the file rather than that function")

        XCTAssertTrue(body[..<end.lowerBound].contains(".frame(width:"), """
            The notice harness renders without proposing a width. ImageRenderer draws an \
            animating view's text only when it is given a size, measured next door, so \
            every surface over there that carries a repeating animation is now being \
            measured with its words missing and nothing reports it (#592, #612).
            """)
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
    private func heightAt(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Every surface in the ink harness, checked for the thing ink cannot see.
    ///
    /// A layout that wraps gets taller as it narrows. One that truncates keeps its
    /// height and drops words instead, and both measure as plenty of ink, so the
    /// harness next door cannot tell them apart (#411).
    ///
    /// Honest about its reach: this catches a surface whose whole height stops
    /// moving, and it will miss a truncating line sitting beside something else
    /// that does wrap, which is how the export screen hid one of its two. Looking
    /// at the rendered pages is still the thing that finds those.
    func testNoMeasuredSurfaceTruncatesWhenTheWindowNarrows() throws {
        var offenders: [String] = []
        for state in BannerLegibilityTests.measuredStates {
            let needed = requiredWidth(state.view)
            guard needed > Self.narrowestPane else { continue }
            let wide = heightAt(state.view, width: 900)
            let narrow = heightAt(state.view, width: 400)
            if narrow <= wide {
                offenders.append("\(state.name): wants \(Int(needed))pt and stays "
                                 + "\(Int(wide))pt tall at both widths")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            These surfaces need more width than a narrow pane gives them and do not \
            get taller when squeezed, which means they are dropping words:

            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The line under the export banner, guarded at the source (#411).
    ///
    /// A source check rather than a measured one, and the reason is worth stating
    /// because two measured versions of this were written first and BOTH passed on
    /// the broken layout:
    ///
    /// * Measuring the note on its own forces it into a 300pt frame, which makes
    ///   it wrap whether or not it is allowed to.
    /// * Measuring the whole export screen sees nothing either: the line is capped
    ///   at 300pt whatever the window does, and a `Spacer()` absorbs the
    ///   difference, so the screen is 542pt tall at 400 wide with the fix and
    ///   542pt without it.
    ///
    /// So nothing about the geometry moves when this line loses half its words.
    /// The defect was found by looking at the rendered page, and what can be
    /// guarded automatically is that the view still declares it may wrap.
    func testTheArchiveNoteStillDeclaresThatItWraps() throws {
        // Comments stripped including trailing ones, the same cut as
        // VisibleRefusalGuardTests.code: `.opacity(1) // .fixedSize(...)`
        // satisfied this check until the mutation registry recorded exactly
        // that break (#416, L103).
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/ExportDoneSummary.swift"),
            encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("*") }
            .map { line -> String in
                guard let slashes = line.range(of: "//") else { return line }
                return String(line[..<slashes.lowerBound])
            }
            .joined(separator: "\n")

        XCTAssertTrue(source.contains("fixedSize(horizontal: false, vertical: true)"), """
            ExportArchiveNote no longer says it may grow taller, so it goes back to \
            one line and drops the end of its sentence. On a failed export that is \
            the half naming what to do about it.
            """)
    }

    /// Both sentences are too long for one line at the width they are held to, so
    /// the wrap above is load bearing rather than decorative.
    func testTheArchiveNoteSentencesNeedMoreThanOneLine() {
        for incomplete in [true, false] {
            let note = ExportArchiveNote(isIncomplete: incomplete)
            XCTAssertGreaterThan(requiredWidth(Text(note.message).font(.light(11))),
                                 ExportArchiveNote.width, """
                "\(note.message)" now fits on one line at \
                \(Int(ExportArchiveNote.width))pt, so the wrapping guard above is no \
                longer protecting anything and this pair should be rethought.
                """)
        }
    }

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
