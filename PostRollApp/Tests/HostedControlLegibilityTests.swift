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

    var body: some View {
        EventRow(event: event, isSelected: isSelected, renameText: .constant(""))
            .padding(.horizontal, Spacing.rowInset)
            .padding(.vertical, Spacing.rowV)
            .background(EventRowBackground(eventID: event.id,
                                           isSelected: isSelected,
                                           hover: hover,
                                           selectionNamespace: selectionNamespace))
    }
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

    /// The ink threshold, kept for the two checks that are ABOUT ink (#614).
    ///
    /// Everything in this file that asks whether words reached the screen now
    /// asks `WordFootprint` instead, which measures the type by taking it away
    /// rather than by counting how unlike its background a surface is. What is
    /// left here is the pair of measurements recording what the two renderers
    /// do to a control that has no words at all, where ink is exactly the
    /// quantity in question.
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
                        height: CGFloat = 90,
                        wordless: Bool = false) throws -> NSBitmapImageRep {
        try WordFootprint.hosted(ZStack {
            Color.cream
            view.padding(Spacing.md)
        }.frame(width: width, height: height),
                                 size: CGSize(width: width, height: height),
                                 wordless: wordless)
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
                    regeneratingDays: [.thursday, .wednesday],
                    staleDays: []) ?? ""))), 90),
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
        let hosted = WordFootprint.ink(try render(ProgressView(), height: 40))

        let imageRendered: Double = try {
            let renderer = ImageRenderer(content: ZStack {
                Color.cream
                ProgressView().padding(Spacing.md)
            }.frame(width: 520, height: 40))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            return WordFootprint.ink(try XCTUnwrap(NSBitmapImageRep(data: tiff)))
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

    /// Every hosted state puts its words on the page (#614).
    ///
    /// This used to ask for a share of the render to be ink, which on these two
    /// states is mostly the menu, the bar and the spinner around the words. Now
    /// it asks what the words themselves are worth, by rendering each state
    /// again with its type switched off and comparing the two.
    func testEveryHostedStateDrawsSomethingLegible() throws {
        for state in states {
            let share = WordFootprint.share(
                try render(state.view, height: state.height),
                try render(state.view, height: state.height, wordless: true))
            print(String(format: "  %.4f  hosted, %@", share, state.name))

            XCTAssertGreaterThan(share, WordFootprint.drawn, """
                Switching every word off "\(state.name)" changed \
                \(String(format: "%.4f", share)) of the render, which is nothing, so \
                what Dan is meant to read on that control is not on the page.
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
        let row = EventListRowPreview(event: sampleEvent, isSelected: isSelected)
            .withAppOwners(AppOwners())
            .background(PaintedSurfaces.deepPage)
            .frame(width: width)

        // The height the row asks for, taken before the render so both renders
        // are the same size and a difference between them is the type rather
        // than a row that laid out differently.
        let sizing = NSHostingView(rootView: row)
        let height = sizing.fittingSize.height
        XCTAssertGreaterThan(height, 30,
                             "the row laid out \(height)pt tall, which is not a row; "
                             + "the measurement would be of nothing")

        return try WordFootprint.hosted(row,
                                        size: CGSize(width: width, height: height),
                                        wordless: wordless)
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

                let share = WordFootprint.share(
                    try renderRow(isSelected: isSelected, width: width, wordless: false),
                    try renderRow(isSelected: isSelected, width: width, wordless: true))
                print(String(format: "  %.4f  row %@, %@", share, state, where_))

                XCTAssertGreaterThan(share, WordFootprint.drawn, """
                    Switching every word off a row \(state), \(where_) \
                    (\(Int(width))pt) changed \(String(format: "%.4f", share)) of the \
                    render, which is nothing. The name, the organisation, the date and \
                    the stage are in the view tree and are not on the screen, and the \
                    fill and the rose gold spine this row paints for itself would keep \
                    a flat ink threshold happy on their own (L141).
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
                            isSelected: Bool,
                            wordless: Bool = false) throws -> NSBitmapImageRep {
        let row = isSelected ? PaintedSurfaces.eventRowSelected
                             : PaintedSurfaces.eventRowAtRest
        let pill = StagePill(state: state, isSelected: isSelected).background(row)

        let size = NSHostingView(rootView: pill).fittingSize
        XCTAssertGreaterThan(size.width, 20,
                             "the \(state) pill laid out at \(size.width)pt wide, "
                             + "which is not a pill; the measurement below would be of "
                             + "nothing")
        return try WordFootprint.hosted(pill, size: size, wordless: wordless)
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
                let share = WordFootprint.share(
                    try renderPill(state, isSelected: isSelected),
                    try renderPill(state, isSelected: isSelected, wordless: true))
                measured.append(("\(state), row \(where_)", share))

                XCTAssertGreaterThan(share, WordFootprint.drawn, """
                    Switching the \(state) pill's label off on a row \(where_) changed \
                    \(String(format: "%.4f", share)) of the render, which is nothing, \
                    so the label is in the view tree and not on the screen. The wash \
                    and the busy dot are marks whatever the word does.
                    """)
            }
        }
        for (name, share) in measured.sorted(by: { $0.1 < $1.1 }) {
            print(String(format: "  %.4f  %@", share, name))
        }
    }

    /// The pill measurement can fail, or the walk above is decoration (L1).
    ///
    /// A capsule whose label is drawn in its own wash is the defect in bare
    /// form, and it is the one this file exists for. Under the ink threshold
    /// this replaced, that capsule still measured as a drawn pill and the proof
    /// had to be that the number was small; under the footprint it is the
    /// stronger statement that taking the label away changes NOTHING, because
    /// there was nothing to take.
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

        func share(_ ink: Color) throws -> Double {
            let size = NSHostingView(rootView: capsule(ink)).fittingSize
            return WordFootprint.share(
                try WordFootprint.hosted(capsule(ink), size: size, wordless: false),
                try WordFootprint.hosted(capsule(ink), size: size, wordless: true))
        }

        let invisible = try share(pill.wash.composited(over: PaintedSurfaces.eventRowAtRest))
        let legible = try share(pill.ink)

        XCTAssertLessThan(invisible, WordFootprint.drawn, """
            A pill label drawn in the colour of its own wash measured \
            \(String(format: "%.4f", invisible)) as a footprint, above the floor the \
            walk above uses, so that walk would pass on a pill showing no words.
            """)
        XCTAssertGreaterThan(legible, WordFootprint.drawn * 5,
                             "the same label in its real ink has to be worth far more "
                             + "than the floor, or the pill render is not reading the "
                             + "type at all")
    }

    // What ImageRenderer does to an animating view is measured by
    // `testTheRendererDrawsAnimatingWordsOnlyWhenItIsGivenASize` below, which
    // is one check where there were two: the older one compared a hosted pill's
    // ink against an image-rendered pill's, which is a difference between two
    // renderers as well as between a drawn word and a missing one, and it said
    // nothing about the size that turned out to be the whole mechanism (#612).

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
        try WordFootprint.hosted(
            OCRProgressBody(eventName: "Spring Gala", live: { _ in live }, onCancel: {})
                .frame(width: width, height: 400)
                .background(PaintedSurfaces.page),
            size: CGSize(width: width, height: 400),
            wordless: wordless)
    }

    /// The screen Dan watches for minutes while a program is read, drawn (#607).
    ///
    /// Every notice, every stage pill and the whole event list are rendered and
    /// measured, and this one never was, so nothing had ever confirmed its
    /// words reach the screen.
    ///
    /// It used to carry a floor of its own, 0.005 where the rest of the file
    /// asked 0.01, honestly measured against this surface: a whole detail pane
    /// holding a name, two short lines, a timer and a footer, centred in a great
    /// deal of empty page. That is the drift #614 is about, a sparse screen
    /// earning a lower bar because that is what it happened to measure. The
    /// screen's own words are the same size whatever it is centred in, and this
    /// now measures those.
    func testTheReadingScreenDrawsItsWords() throws {
        for state in Self.readingStates {
            let share = WordFootprint.share(
                try renderReadingScreen(state.live, wordless: false),
                try renderReadingScreen(state.live, wordless: true))
            print(String(format: "  %.4f  reading, %@", share, state.name))

            XCTAssertGreaterThan(share, WordFootprint.drawn, """
                Switching every word off the reading screen "\(state.name)" changed \
                \(String(format: "%.4f", share)) of the render, which is nothing. The \
                show's name, the phase, the timer and the footer are in the view tree \
                and are not on the screen, which is the state Dan sits in front of for \
                minutes at a time. The shimmer rail is a mark on the page whatever they \
                do, so a flat ink threshold could not have said this (L141).
                """)
        }
    }

    /// The screen still draws when the window is dragged narrow.
    func testTheReadingScreenStillDrawsWhenNarrow() throws {
        for state in Self.readingStates {
            let share = WordFootprint.share(
                try renderReadingScreen(state.live, wordless: false, width: 300),
                try renderReadingScreen(state.live, wordless: true, width: 300))
            XCTAssertGreaterThan(share, WordFootprint.drawn,
                                 "the reading screen \"\(state.name)\" lost its words "
                                 + "at 300pt wide")
        }
    }

    /// Where the animation trap actually reaches, measured rather than assumed.
    ///
    /// #607 was filed expecting this screen to be the stage pill's case again:
    /// it carries a `repeatForever` shimmer, and #592 measured `ImageRenderer`
    /// drawing an animating pill's capsule and dropping its word. Through
    /// `ImageRenderer` at the size the harness gives it, this screen's words are
    /// worth a measurable share of the render, printed on each run, so they are
    /// drawn.
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
        let screen = OCRProgressBody(eventName: "Spring Gala", live: { _ in live },
                                     onCancel: {})
            .frame(width: 520, height: 400)
            .background(PaintedSurfaces.page)

        let share = WordFootprint.share(
            try WordFootprint.imageRendered(screen, wordless: false),
            try WordFootprint.imageRendered(screen, wordless: true))
        print(String(format: "  reading screen through ImageRenderer: %.4f", share))

        XCTAssertGreaterThan(share, WordFootprint.drawn, """
            Through ImageRenderer, switching every word off the reading screen changed \
            \(String(format: "%.4f", share)) of the render, which means the words are \
            no longer being drawn even at a proposed size. The hosted checks above still \
            see this screen, so nothing here is unguarded, but a surface added to \
            BannerLegibilityTests near it would now be measuring its own decoration.
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
        // Through `message(whileDoing: .programRead)`, which is what OCRManager
        // hands this screen, rather than through `localizedDescription`, which
        // is the neutral wording nothing shows here (#626). A fixture that
        // takes a different path from the app is a picture of a screen the app
        // never draws (L48).
        func read(_ error: PythonBridgeError) -> String {
            error.message(whileDoing: .programRead)
        }
        return [
            ("a run that timed out", read(.timedOut(seconds: 600))),
            ("a read that produced nothing", read(.outputMissing)),
            ("a failure nothing recognised",
             read(.scriptFailed(
                exitCode: 1,
                stderr: "Traceback (most recent call last):\n"
                    + "  File \"postroll/ai/ocr.py\", line 214, in read_program\n"
                    + "RuntimeError: the page bundle was rejected by the service"))),
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
                let share = WordFootprint.share(whole, without)
                print(String(format: "  %.4f  %@, %@", share, state.name, part.rawValue))

                XCTAssertGreaterThan(share, WordFootprint.drawn, """
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
            XCTAssertGreaterThan(WordFootprint.share(whole, without), WordFootprint.drawn,
                                 "the failure screen lost \"\(part.rawValue)\" at "
                                 + "\(Int(Self.narrowestPane))pt wide")
        }
    }

    // MARK: - What the two program-read screens call themselves (#622)

    /// The app's internal name for the step, which Dan never has to learn.
    private static let jargon = "OCR"

    /// Whether a line of source puts that term in front of a person.
    ///
    /// String literals only. The type names in this file are full of it
    /// (`OCRFailureBody`, `OCRProgressText`), and none of them is a word
    /// anybody reads, so a check over the raw line would be answered by the
    /// declarations rather than by the copy.
    private static func showsJargon(_ line: String) -> Bool {
        line.matches(of: #/"[^"]*"/#)
            .contains { String($0.output).uppercased().contains(jargon) }
    }

    /// Neither program-read screen is headed in jargon (#622).
    ///
    /// The failure screen was headed "OCR Failed" while the screen immediately
    /// before it says "Reading Program". They are only ever read in sequence,
    /// and read that way the pair sounded like two different features on the
    /// one screen that reports a paid read did not work and offers the way to
    /// run it again (L21, L118).
    ///
    /// Asserted on the strings the views draw from, and on the rule rather than
    /// on either wording: a heading may not name the step by the term the app
    /// uses in front of Dan nowhere else, and it has to name the thing being
    /// read, so a later rewording that keeps both passes (L103).
    func testNeitherProgramReadScreenIsHeadedInJargon() {
        for (screen, heading) in [
            ("the reading screen", OCRProgressText.readingHeading),
            ("the failure screen", OCRProgressText.failureHeading),
        ] {
            XCTAssertFalse(heading.uppercased().contains(Self.jargon), """
                \(screen) is headed "\(heading)", which names the step by the app's own \
                internal term for it. That word appears nowhere else Dan can see, so the \
                screen introduces a name for a thing he already has a name for.
                """)
            XCTAssertTrue(heading.lowercased().contains("program"), """
                \(screen) is headed "\(heading)", which does not name the thing being \
                read. These two screens are read one after the other and have to sound \
                like one feature.
                """)
        }
    }

    /// And the screens actually draw from those strings (#622, L3).
    ///
    /// Naming the heading somewhere the check can read it proves nothing on its
    /// own: a heading typed back into the view would leave the constant above
    /// correct, unread and passing, which is the shape of a value written but
    /// never used (L46). So the file that draws these screens may not carry the
    /// word at all.
    ///
    /// The whole file rather than one declaration, because the rule really is
    /// file-wide here: both screens live in it, and a literal naming the step
    /// that way is an offence wherever it sits, so there is no legitimate other
    /// use that could answer for a broken one (L135).
    func testTheProgramReadScreensDrawNoJargonOfTheirOwn() throws {
        let relative = "Sources/Views/OCRProgressView.swift"
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent(relative)
        let code = SwiftSourceText.withoutComments(
            try String(contentsOf: url, encoding: .utf8))

        let offenders = code.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                guard Self.showsJargon(String(line)) else { return nil }
                return "\(relative):\(index + 1)  "
                    + line.trimmingCharacters(in: .whitespaces)
            }

        XCTAssertTrue(offenders.isEmpty, """
            These lines show Dan the app's internal name for the program read:

            \(offenders.joined(separator: "\n"))

            The words on these screens come from OCRProgressText, so they can be read \
            as a pair and checked as one. Put the wording there and draw it from here.
            """)
    }

    /// The matcher above is asked directly what it can see (L1).
    ///
    /// The file is clean once the fix lands, so a matcher reading nothing and a
    /// matcher reading everything give the same silent pass. What has to be seen
    /// to fail is the matcher, not the tree around it.
    func testTheJargonMatcherReadsLiteralsRatherThanSymbols() {
        for line in ["                Text(\"OCR Failed\")",
                     "        Text(\"Reading with OCR\")",
                     "            Label(\"ocr failed\", systemImage: \"x\")"] {
            XCTAssertTrue(Self.showsJargon(line),
                          "the check cannot see \(line.trimmingCharacters(in: .whitespaces)) "
                          + "as jargon shown on screen, so a heading spelled that way is "
                          + "exempt from the rule and reads exactly like a clean file")
        }

        for line in ["                Text(OCRProgressText.failureHeading)",
                     "struct OCRFailureBody: View {",
                     "    private var run: OCRManager.Run? { ocrManager.run(for: event.id) }"] {
            XCTAssertFalse(Self.showsJargon(line),
                           "the check reports \(line.trimmingCharacters(in: .whitespaces)) "
                           + "as jargon on screen, which it is not: a type name is not a "
                           + "word anybody reads. A rule that fires on correct code is the "
                           + "rule people learn to work around")
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
        XCTAssertEqual(WordFootprint.share(once, again), 0, accuracy: 0.00001, """
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
        let invisible = WordFootprint.share(try render(card(PaintedSurfaces.page)), blank)
        let legible = WordFootprint.share(try render(card(Color.warmDark)), blank)

        XCTAssertLessThan(invisible, WordFootprint.drawn, """
            type drawn in the colour of the page behind it measures \
            \(String(format: "%.4f", invisible)) as a footprint, which clears the floor \
            the checks above use, so those checks would pass on a screen showing nothing
            """)
        XCTAssertGreaterThan(legible, WordFootprint.drawn * 5, """
            the same sentence in a readable colour measures \
            \(String(format: "%.4f", legible)), which is not far enough above the floor \
            for the floor to mean anything
            """)
    }

    // MARK: - What the renderer next door can see (#612)
    //
    // The sweep over the thirty-eight measured states lives in
    // BannerLegibilityTests, beside the states themselves, where it replaced
    // that file's ink threshold (#614). What is here is the pair of facts that
    // sweep rests on, both about the renderer rather than about any one screen.

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
            WordFootprint.share(try WordFootprint.imageRendered(content, wordless: false),
                      try WordFootprint.imageRendered(content, wordless: true))
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

            XCTAssertLessThan(one.ownSize, WordFootprint.drawn, """
                Switching the words off \(one.name) rendered at its own size changed \
                \(String(format: "%.4f", one.ownSize)) of the image, which means the \
                words were there to lose. ImageRenderer has learned to draw an animating \
                view unsized, and the reasoning in this file, in #592 and in #607 needs \
                redoing: the sweep below is calibrated on this being the case that fails.
                """)
            XCTAssertGreaterThan(one.sized, WordFootprint.drawn, """
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

        // `static func`, not `private func`: #1257 took two sweeps out of that
        // class into sliced ones, and they call this helper rather than
        // carrying a copy, so it had to stop being private. The check is about
        // the helper's BODY either way.
        let start = try XCTUnwrap(code.range(of: "static func render("),
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
        // tests/swift_visible_failure_rules.py's `code` (#1089):
        // `.opacity(1) // .fixedSize(...)` satisfied this check until the
        // mutation registry recorded exactly that break (#416, L103).
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
                regeneratingDays: [.thursday, .wednesday], staleDays: []) ?? ""))

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
            let share = WordFootprint.share(
                try render(state.view, width: 300, height: state.height),
                try render(state.view, width: 300, height: state.height, wordless: true))
            XCTAssertGreaterThan(share, WordFootprint.drawn,
                                 "\"\(state.name)\" lost its words at 300pt wide")
        }
    }
}

#if POSTROLL_TESTS
extension HostedControlLegibilityTests {

    /// Every surface this file measures, each paired with the pixels it draws
    /// (#623).
    ///
    /// Built by walking the SAME collections the measurement tests walk, and by
    /// calling the SAME render helpers, rather than by listing the screens
    /// again here. That is what makes "the sheet shows what the checks know
    /// about" true by construction instead of by somebody remembering: a state
    /// added to `readingStates` or a case added to `StagePillState` is in the
    /// sheet the moment it is measured, and a hand-kept list would simply be
    /// missing it while still reporting a full sheet (L96).
    ///
    /// It is also why there is no second renderer. A picture drawn by code the
    /// checks do not use would be a picture of a screen the app never draws,
    /// which is the trap #607 recorded when the reading screen's phase table
    /// still lived in the view (L48).
    private var reviewSurfaces: [(name: String, render: () throws -> NSBitmapImageRep)] {
        var surfaces: [(String, () throws -> NSBitmapImageRep)] = []

        for state in states {
            surfaces.append((state.name, { try self.render(state.view,
                                                           height: state.height) }))
        }

        for (where_, width) in Self.sidebarWidths {
            for isSelected in [false, true] {
                let state = isSelected ? "selected" : "at rest"
                surfaces.append(("event row \(state) \(where_)",
                                 { try self.renderRow(isSelected: isSelected,
                                                      width: width, wordless: false) }))
            }
        }

        for state in StagePillState.allPillStates {
            for isSelected in [false, true] {
                let row = isSelected ? "row selected" : "row at rest"
                surfaces.append(("stage pill \(state) \(row)",
                                 { try self.renderPill(state, isSelected: isSelected) }))
            }
        }

        for state in Self.readingStates {
            surfaces.append(("reading screen \(state.name)",
                             { try self.renderReadingScreen(state.live,
                                                            wordless: false) }))
        }

        for state in Self.failureMessages {
            surfaces.append(("failure screen \(state.name)",
                             { try self.renderFailureScreen(state.message) }))
        }

        surfaces.append(("insights report", { try self.renderInsightsReport() }))
        surfaces.append(("caption card", { try self.renderCaptionCard() }))
        surfaces.append(("photo day grid, thumbnails still loading",
                         { try self.renderPhotoDay() }))
        surfaces.append(("tag fields, clean", { try self.renderTagFields(handles: "@guestartist") }))
        surfaces.append(("tag fields, a name typed as a handle",
                         { try self.renderTagFields(handles: "@guestartist, DPR Dance") }))
        surfaces.append(("settings, nothing saved yet",
                         { try self.renderSettings(key: nil, book: Self.emptyBook()) }))
        surfaces.append(("settings, a key and a full handle book",
                         { try self.renderSettings(key: "sk-ant-api03-not-a-real-key",
                                                   book: Self.filledBook()) }))
        // From the one list, so the sheet and the check that each of these
        // actually DREW something cannot disagree about which screens there
        // are (#947, L70).
        for screen in wholeScreens {
            surfaces.append((screen.name, { try screen.render(false) }))
        }

        return surfaces
    }

    /// Every whole screen the sheet draws, and how to draw it either way.
    ///
    /// `(Bool) throws -> NSBitmapImageRep` rather than a plain closure, because
    /// #947 needs each one rendered TWICE: once normally and once with its
    /// words switched off. The difference between the two is what proves type
    /// reached the page, and a surface whose renderer produced a blank image,
    /// an error state, or a screen that failed to lay out satisfies a check on
    /// the NAME completely (L98, L84).
    ///
    /// Ink alone would be the wrong measure: a screen paints its own background
    /// and chrome, and that measures as presence (L141, L146).
    var wholeScreens: [(name: String, render: (Bool) throws -> NSBitmapImageRep)] {
        [
            ("screen: ProgramUploadView",
             { try self.renderProgramUploadScreen(wordless: $0) }),
            ("screen: OCRProgressView",
             { try self.renderOCRProgressScreen(estimateSeconds: 95, wordless: $0) }),
            ("screen: OCRProgressView, no estimate yet",
             { try self.renderOCRProgressScreen(estimateSeconds: nil, wordless: $0) }),
            ("screen: PhotoAssignmentView",
             { try self.renderPhotoAssignmentScreen(wordless: $0) }),
            ("screen: AssetGenerationView",
             { try self.renderAssetGenerationScreen(wordless: $0) }),
            ("screen: OCRReviewView",
             { try self.renderOCRReviewScreen(wordless: $0) }),
            ("screen: ExportView",
             { try self.renderExportScreen(wordless: $0) }),
            ("screen: CaptionReviewView",
             { try self.renderCaptionReviewScreen(wordless: $0) }),
        ]
    }

    /// What the sheet holds, by name, for a check in another file (#937).
    ///
    /// The surfaces themselves stay private: handing out the renderers would
    /// let another file draw them, and then two files would decide what the
    /// sheet is. Only the names leave.
    var reviewSurfaceNames: [String] { reviewSurfaces.map(\.name) }

    /// The sheet names every state the checks in this file measure (#623).
    ///
    /// Without this the coverage claim above is unguarded: `reviewSurfaces` is
    /// checked against its own length, so deleting a whole loop out of it
    /// shrinks both sides of that comparison and the dump goes on passing while
    /// the sheet quietly stops showing the stage pills. A count compared with
    /// itself can only prove it is self-consistent (L70).
    ///
    /// So this asks the question from the other side, against the collections
    /// the measurement tests walk: for each state they measure, is there a
    /// picture of it. A state added there and missed here fails, which is the
    /// direction a hand-kept list always fails in (L96).
    func testTheSheetShowsEveryStateTheseChecksMeasure() {
        let names = reviewSurfaces.map(\.name)

        func expect(_ fragment: String, _ what: String) {
            XCTAssertTrue(names.contains { $0.contains(fragment) }, """
                Nothing in the review sheet shows \(what) ("\(fragment)"), so a visual \
                change to it can only be reviewed by launching the app, which is the \
                thing this sheet exists to replace.
                """)
        }

        for state in states { expect(state.name, "the \(state.name)") }
        for state in StagePillState.allPillStates {
            expect("stage pill \(state)", "the \(state) stage pill")
        }
        for state in Self.readingStates {
            expect("reading screen \(state.name)", "the reading screen \(state.name)")
        }
        for state in Self.failureMessages {
            expect("failure screen \(state.name)", "the failure screen for \(state.name)")
        }
        expect("event row at rest", "an event row at rest")
        expect("event row selected", "a selected event row")

        // The three screens that could only ever be reviewed by launching the
        // app (#645). Named individually rather than counted, so removing one
        // fails here instead of shrinking both sides of the dump's own count
        // (L70).
        expect("insights report", "the Insights report")
        expect("caption card", "a day's caption card")
        expect("photo day grid", "a posting day's photo grid")
        // Both states, because a warning is only reviewable beside the surface
        // WITHOUT it: a note that looks like part of the furniture reads as
        // fine until the two are seen together (#919).
        expect("tag fields, clean", "the tag fields with nothing to report")
        expect("tag fields, a name typed as a handle",
               "the tag fields warning that a value will be credited by name")
        // Settings, which nothing rendered at all until #918. Two states,
        // because the pane that lists what the app has learned is a different
        // picture when it has learned nothing, and the first run is the empty
        // one (L10).
        expect("settings, nothing saved yet",
               "the Settings screen on a machine with no key and an empty book")
        expect("settings, a key and a full handle book",
               "the Settings screen with the saved handles panes filled")
    }

    /// The Insights report, at the size the pane gives it (#645).
    ///
    /// A measured fixture rather than an invented one where it matters: the
    /// counts and the date range are the shape a real fortnight produces, and
    /// the findings carry all three confidence levels, because the dot beside
    /// each one is drawn from a three entry table and a fixture holding only
    /// "high" would picture a screen missing two thirds of it (L113).
    ///
    /// The store is given a file in a temporary directory, so drawing this
    /// cannot read or write the real analytics (L2). `InsightReportView` is
    /// handed its report and fetches nothing, which is why it can be drawn at
    /// all; the pane around it goes to disk.
    private static var insightsReport: InsightReport {
        func finding(_ headline: String, _ evidence: String,
                     _ confidence: InsightFinding.Confidence) -> InsightFinding {
            InsightFinding(id: UUID(), headline: headline,
                           evidence: evidence, confidence: confidence)
        }

        let feed = InsightFindings(
            captionPatterns: [
                finding("Captions opening on a performer's name do better",
                        "9 of your 12 strongest posts name somebody in the first line.",
                        .high),
            ],
            hashtagPatterns: [
                finding("Venue tags outperform genre tags",
                        "Posts tagging the room reached 40% further than those tagging the form.",
                        .medium),
            ],
            contentTypePatterns: [
                finding("Carousels hold attention longer than single frames",
                        "Median watch time 4.1s against 2.3s across 18 posts.",
                        .high),
            ],
            timingPatterns: [
                finding("Thursday evening posts travel furthest",
                        "Too few Sunday posts to say anything about the weekend yet.",
                        .low),
            ])

        let story = InsightFindings(
            captionPatterns: [
                finding("Stories with no caption at all do fine",
                        "The picture carries it; 6 of 8 top stories had no text.",
                        .medium),
            ],
            hashtagPatterns: [],
            contentTypePatterns: [
                finding("Behind the scenes frames get the most replies",
                        "11 replies across 4 stories from the wings.",
                        .high),
            ],
            timingPatterns: [])

        // Pinned, not read from the clock: a fixture whose meaning is a date
        // range walks into a different state as real time passes (L130).
        let end = Date(timeIntervalSince1970: 1_760_000_000)
        return InsightReport(
            id: UUID(),
            generatedAt: end,
            dateRangeStart: end.addingTimeInterval(-14 * 24 * 60 * 60),
            dateRangeEnd: end,
            postCount: 26, storyCount: 8, feedCount: 18,
            summary: "Naming the performer in the first line is doing more work "
                + "than anything else you changed this fortnight.",
            feedFindings: feed,
            storyFindings: story,
            brandVoiceSuggestions: [
                "Keep opening on a name.",
                "The venue is worth tagging; the genre is not.",
            ],
            caveats: [
                "Eight stories is not many, so treat the story findings as a hint.",
            ],
            // A report that is partly uncontrolled, so the notice #720 added is
            // one of the surfaces this sheet renders and measures rather than a
            // state nothing ever draws.
            analyzedCount: 26, uncontrolledCount: 7, uncreditedCount: 2,
            uncontrolledOrgs: ["newchoir"])
    }

    private func renderInsightsReport(width: CGFloat = 700) throws -> NSBitmapImageRep {
        let store = AnalyticsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("review-sheet-analytics-\(UUID().uuidString).json"))

        let view = ScrollView {
            // A link handler is passed so the notice's control DRAWS in
            // the sheet. Left nil the button is absent, and a surface
            // that never renders cannot be reviewed or measured (#720).
            InsightReportView(report: Self.insightsReport) {}
                .padding(Spacing.lg)
        }
        .environment(store)
        .frame(width: width, height: 900)
        .background(PaintedSurfaces.page)

        return try WordFootprint.hosted(view,
                                        size: CGSize(width: width, height: 900),
                                        wordless: false)
    }

    /// One day's caption card, expanded, which is the bulk of the review pane
    /// (#645).
    ///
    /// Carries findings as well as a caption, because the findings panel is the
    /// feature on that screen: it is where the deterministic credit checks
    /// report a handle that was asked for and never appeared, and a fixture
    /// with a clean caption would picture the card with its most important part
    /// missing.
    private func renderCaptionCard(width: CGFloat = 700) throws -> NSBitmapImageRep {
        var caption = DayCaption()
        caption.caption = "Isabel Ruiz closing the second act at the Green Room, "
            + "with the band still going behind her.\n\nShot for @thegreenroom42."
        caption.hashtags = ["#nycjazz", "#livemusicphotography", "#greenroom42"]
        caption.altTexts = ["A singer mid phrase, lit warm from stage left."]
        caption.generatedCaption = caption.caption

        var day = PostingDay(day: .wednesday)
        day.tagHandles = ["@thegreenroom42"]
        day.nameMentions = ["Isabel Ruiz"]

        // Nothing saved is read, so the picture is the same on any machine and
        // the render cannot reach Dan's own tags (L2).
        let hashtags = HashtagStore(loadingSaved: false)
        hashtags.globalTags = ["#nycjazz", "#livemusicphotography"]

        let view = ScrollView {
            CaptionSection(day: .wednesday,
                           postingDay: day,
                           caption: .constant(caption),
                           isExpanded: true,
                           onToggle: {},
                           onRevise: { _, _ in })
                .padding(Spacing.lg)
        }
        .environment(hashtags)
        .frame(width: width, height: 900)
        .background(PaintedSurfaces.page)

        return try WordFootprint.hosted(view,
                                        size: CGSize(width: width, height: 900),
                                        wordless: false)
    }

    /// A posting day's photo grid, which is most of the assignment screen
    /// (#645).
    ///
    /// The photographs are written into a temporary directory rather than taken
    /// from anywhere real: this must not reach Dan's library, and a fixture
    /// pointing at whatever happens to be on disk would draw a different
    /// picture every run (L2).
    ///
    /// Six of them, because the grid wraps and a fixture of one or two would
    /// picture a row that never wraps, which is the shape the screen is
    /// actually in (L101).
    ///
    /// ## What this picture does NOT show, said out loud
    ///
    /// The thumbnails come out as the loading placeholder, because the images
    /// load asynchronously and the render captures before they arrive. So the
    /// surface is named for the state it is really in rather than for the one
    /// it looks like it should be: a recorded picture that photographed a
    /// loading state and passed as the screen at rest is exactly the trap L84
    /// records, and a placeholder is itself a mark on the page (L115).
    ///
    /// What it does cover is everything that moves when type or colour moves:
    /// the day label, the count badge, the subtitle, the remove buttons, the
    /// add control and the rule under it. Drawing the photographs themselves
    /// would need the loads awaited, which is its own piece of work.
    private func renderPhotoDay(width: CGFloat = 700) throws -> NSBitmapImageRep {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-sheet-photos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [URL] = []
        for index in 1...6 {
            let size = NSSize(width: 400, height: 300)
            let image = NSImage(size: size)
            image.lockFocus()
            // A recognisable frame rather than flat colour, so a thumbnail that
            // failed to load is visibly different from one that drew.
            NSColor(calibratedHue: CGFloat(index) / 8.0, saturation: 0.35,
                    brightness: 0.75, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()

            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { throw XCTSkip("the fixture photograph could not be encoded") }

            let url = folder.appendingPathComponent("DSC_100\(index).jpg")
            try png.write(to: url)
            urls.append(url)
        }

        let view = ScrollView {
            PhotoDaySection(label: "Wednesday",
                            subtitle: "Carousel, up to 10 photos",
                            photos: .constant(urls),
                            onAddPhotos: {})
                .padding(Spacing.lg)
        }
        .frame(width: width, height: 700)
        .background(PaintedSurfaces.page)

        return try WordFootprint.hosted(view,
                                        size: CGSize(width: width, height: 700),
                                        wordless: false)
    }

    /// The two tag fields, with and without something to report (#919).
    ///
    /// `handles` is what has been typed into the @handles field. The panel
    /// starts expanded when it holds content, so passing a value is also what
    /// makes the fields visible at all.
    private func renderTagFields(handles: String,
                                 width: CGFloat = 700) throws -> NSBitmapImageRep {
        let view = ScrollView {
            PerformerAssignmentSection(
                day: .wednesday,
                performers: [],
                eventHandles: "@dciny, @thejoyce",
                selectedPerformerIDs: .constant([]),
                handles: .constant(handles),
                names: .constant("Jordan Langworthy"),
                isCarouselDay: true,
                creditedFromPhotos: [],
                onChanged: {})
                .padding(Spacing.lg)
        }
        .frame(width: width, height: 700)
        .background(PaintedSurfaces.page)

        return try WordFootprint.hosted(view,
                                        size: CGSize(width: width, height: 700),
                                        wordless: false)
    }

    // MARK: - The whole screens the app can show (#937)
    //
    // Every one of these was absent from the sheet until now, and what WAS on
    // it were their parts: the caption card, the photo day grid, the tag fields
    // panel, the generation-done body, each drawn with plain values. Those are
    // renderable precisely because they take values; the screens around them
    // take an Event and reach for stores, which is why none of them had ever
    // been drawn.
    //
    // Named `screen: <TypeName>` so `TopLevelScreenCoverageTests` can hold the
    // sheet to what `EventDetailView` can actually show, with no mapping table
    // in between for the two sides to disagree about (L41).

    /// The size a whole screen is drawn at.
    ///
    /// Tall, and scrolled, because these are full pages: a frame that cropped
    /// them would put whatever sits at the bottom, which is usually the action
    /// that moves the event on, below the cut and out of every review.
    static let screenSize = CGSize(width: 900, height: 1100)

    private func renderScreen(_ view: some View,
                              wordless: Bool = false) throws -> NSBitmapImageRep {
        try WordFootprint.hosted(
            ScrollView { view }
                .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                .background(PaintedSurfaces.page),
            size: Self.screenSize, wordless: wordless)
    }

    /// A scratch directory per render, so nothing drawn here can read or write
    /// the events, photographs or previews the app really has (L2).
    private static func scratchRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postroll-screen-render-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        return root
    }

    /// An event with enough on it to draw, built the way the app builds one.
    ///
    /// A real shape rather than a tidy one: a name long enough to wrap, an
    /// organisation and a venue that are the sort of thing a program carries,
    /// and a date, because several of these screens put it in their header and
    /// a missing one renders a header nobody would ever see (L48).
    nonisolated static func sampleEvent(stage: EventStage = .created) -> Event {
        var event = Event(name: "An Evening of New Choreography",
                          org: "Battery Dance", venue: "Wagner Park",
                          date: Date(timeIntervalSince1970: 1_788_000_000),
                          shootType: .fullShow)
        event.stage = stage
        return event
    }

    /// The app's state, on a store and a data root of its own.
    @MainActor
    static func scratchAppState(_ event: Event) -> AppState {
        let root = scratchRoot()
        return AppState(events: [event],
                        storeURL: root.appendingPathComponent("events.json"),
                        dataRoot: root)
    }

    /// Stage 1: the screen that asks for the program (#937).
    private func renderProgramUploadScreen(wordless: Bool = false) throws -> NSBitmapImageRep {
        let event = Self.sampleEvent(stage: .created)
        return try renderScreen(
            ProgramUploadView(event: event)
                .environment(Self.scratchAppState(event))
                .withAppOwners(AppOwners()),
                                wordless: wordless)
    }

    /// Stage 2: the screen shown while the program is being read (#937).
    ///
    /// With an estimate planted, because the footer's whole job is to say how
    /// long this usually takes, and a store with nothing in it draws the
    /// screen's other half. An empty one is what a first run shows and is worth
    /// having too, so both are on the sheet.
    private func renderOCRProgressScreen(estimateSeconds: Double?,
                                         wordless: Bool = false) throws -> NSBitmapImageRep {
        let event = Self.sampleEvent(stage: .programUploaded)
        let timings = TimingStore(defaults: Self.scratchDefaults())
        if let estimateSeconds {
            timings.recordOCR(seconds: estimateSeconds)
        }
        return try renderScreen(
            OCRProgressView(event: event, timings: timings)
                .environment(Self.scratchAppState(event))
                .withAppOwners(AppOwners()),
                                wordless: wordless)
    }

    /// Stage 3: the screen where photographs are dealt across the week (#937).
    ///
    /// The one screen of the seven that needed no seam at all: it takes the
    /// event and the app's state and nothing else, which is why parts of it
    /// (the photo grid, the tag fields panel) were already renderable and on
    /// the sheet before the screen around them was.
    private func renderPhotoAssignmentScreen(wordless: Bool = false) throws -> NSBitmapImageRep {
        let event = Self.sampleEvent(stage: .photosAssigned)
        return try renderScreen(
            PhotoAssignmentView(event: event)
                .environment(Self.scratchAppState(event))
                // Through the same list the app uses, like its three siblings
                // here (#1007). This renderer was the one screen handed only an
                // AppState, which held for as long as nothing on it read an
                // owner. The posting layout control does, and a missing
                // Observable is a FATAL ERROR rather than a failing assertion,
                // so the whole sheet died and said nothing about the screen.
                .withAppOwners(AppOwners()),
                                wordless: wordless)
    }

    /// Stage 4: the screen that runs the week's generation (#937).
    ///
    /// Configuring rather than running, because a run in flight is what the
    /// reading screen already pictures and this is the state Dan actually
    /// makes a decision on. The timings carry a history, so the phase timeline
    /// and the estimate are drawn from real arithmetic rather than the "~6:00"
    /// fallback, which is a different picture and a rarer one.
    private func renderAssetGenerationScreen(wordless: Bool = false) throws -> NSBitmapImageRep {
        let event = Self.sampleEvent(stage: .assetsGenerated)
        let timings = TimingStore(defaults: Self.scratchDefaults())
        timings.recordGeneration(seconds: 372)
        timings.recordGenerationPhases(captions: 210, blog: 96, packaging: 66)
        return try renderScreen(
            AssetGenerationView(event: event, timings: timings,
                                bakery: ProgramPDFBakery())
                .environment(Self.scratchAppState(event))
                .withAppOwners(AppOwners()),
                                wordless: wordless)
    }

    /// Stage 5: the screen where what was read off the program is corrected (#937).
    ///
    /// With an OCR result on the event, because the screen with nothing to
    /// review is a different and much emptier picture, and the one worth
    /// looking at is the one with performers, pieces and a handle the book
    /// guessed. The guessed handle matters: it is marked as a guess for as long
    /// as it is untouched (#459), and that mark is a thing only a render shows.
    private func renderOCRReviewScreen(wordless: Bool = false) throws -> NSBitmapImageRep {
        var event = Self.sampleEvent(stage: .ocrDone)
        var result = OCRResult()
        result.performers = [
            Performer(name: "Jordan Langworthy", role: "Choreographer"),
            Performer(name: "Sarah Chen", role: "Dancer"),
        ]
        event.ocrResult = result

        let book = HandleBook(defaults: Self.scratchDefaults())
        book.setEntry(name: "Jordan Langworthy", value: "@jordanlangworthy",
                      in: .performer)
        book.setEntry(name: "Battery Dance", value: "@batterydance", in: .org)

        return try renderScreen(
            OCRReviewView(event: event, book: book)
                .environment(Self.scratchAppState(event))
                .withAppOwners(AppOwners()),
                                wordless: wordless)
    }

    /// Stage 7: the screen the week is exported from (#937).
    ///
    /// The account book gets a file of its own in the scratch root. It holds
    /// real follower counts for real accounts, so a render reaching the shared
    /// one would read Dan's numbers into the suite and could write them back
    /// (L2, L222).
    private func renderExportScreen(wordless: Bool = false) throws -> NSBitmapImageRep {
        let event = Self.sampleEvent(stage: .exported)
        let root = Self.scratchRoot()
        return try renderScreen(
            ExportView(event: event,
                       accounts: AccountBook(
                        fileURL: root.appendingPathComponent("accounts.json")),
                       previews: PreviewGraphicsManager())
                .environment(Self.scratchAppState(event))
                .withAppOwners(AppOwners()),
                                wordless: wordless)
    }

    /// Stage 6: the screen the week's captions are read and edited on (#937).
    ///
    /// The last of the seven, and the heaviest. Only the two stores it reads
    /// while DRAWING are handed in; what it does when a button is pressed goes
    /// through PythonBridge and NotificationService, and no render presses a
    /// button.
    private func renderCaptionReviewScreen(wordless: Bool = false) throws -> NSBitmapImageRep {
        let event = Self.sampleEvent(stage: .captionsReviewed)
        let root = Self.scratchRoot()
        return try renderScreen(
            CaptionReviewView(event: event,
                              accounts: AccountBook(
                                fileURL: root.appendingPathComponent("accounts.json")),
                              previews: PreviewGraphicsManager())
                .environment(Self.scratchAppState(event))
                .environment(HashtagStore(loadingSaved: false))
                .withAppOwners(AppOwners()),
                                wordless: wordless)
    }

    /// The Settings screen, which nothing rendered until now (#918).
    ///
    /// Every store it reads is handed in, and that is the whole reason this
    /// could not be done before. Drawn as it stood, this would read Dan's real
    /// API key out of the login keychain, his real handle book, and his real
    /// default posting layout, on every run of the suite and on every machine
    /// including CI (L2). The key and the book are now parameters and the
    /// preset store already came from the environment (#727).
    ///
    /// Tall and scrolled, because the screen is a Form of five sections and a
    /// frame that cropped it would put the saved handles panes, which are the
    /// newest and least seen part of it, below the cut.
    private func renderSettings(key: String?,
                                book: HandleBook,
                                width: CGFloat = 560,
                                height: CGFloat = 1200) throws -> NSBitmapImageRep {
        let view = ScrollView {
            SettingsView(keySource: .fixed(key), book: book)
                // Every owner from the shared list, then the scratch preset
                // store over the top. This harness named its own injections,
                // which is the second list `AppOwners` exists to remove.
                //
                // Found by adding an owner the Settings screen reads: this
                // CRASHED rather than failed, because a view reading a missing
                // `@Environment` traps, and a crash reports zero tests
                // executed rather than a named failure (L41, L96).
                //
                // The preset store still has to be the scratch one, or
                // rendering this screen reads Dan's real preference, so it is
                // applied last and wins.
                .withAppOwners(AppOwners())
                .environment(PostingPresetStore(defaults: Self.scratchDefaults()))
        }
        .frame(width: width, height: height)
        .background(PaintedSurfaces.page)

        return try WordFootprint.hosted(view,
                                        size: CGSize(width: width, height: height),
                                        wordless: false)
    }

    /// A suite of its own per call, so nothing drawn here can reach, or be
    /// reached by, the preferences the app really uses (L2).
    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "settings-render-\(UUID().uuidString)")!
    }

    private static func emptyBook() -> HandleBook {
        HandleBook(defaults: scratchDefaults())
    }

    /// A book with something in all three, because the panes are three separate
    /// stores and one filled book would picture two thirds of the screen in its
    /// empty state while claiming to show the full one (L113).
    ///
    /// The values are the shapes the book really holds rather than tidy ones:
    /// an org whose remembered value is prose instead of a handle is exactly
    /// what #903 was opened about, and it is what the list has to make findable.
    private static func filledBook() -> HandleBook {
        let book = HandleBook(defaults: scratchDefaults())
        book.setEntry(name: "Jordan Langworthy", value: "@jordanlangworthy",
                      in: .performer)
        book.setEntry(name: "Sarah Chen", value: "@sarahchendance", in: .performer)
        book.setEntry(name: "Battery Dance", value: "@batterydance", in: .org)
        book.setEntry(name: "DPR Dance", value: "ask the company", in: .org)
        book.setEntry(name: "Wagner Park", value: "@wagnerpark", in: .venue)
        return book
    }

    /// Writes every one of them into the shared folder (#623).
    ///
    /// Asserts rather than merely producing files: a utility in the suite that
    /// cannot fail is indistinguishable from one that silently stopped working.
    /// It counts what is ON DISK afterwards rather than what the loop meant to
    /// write, because counting the loop is counting itself.
    /// Every screen on the review sheet still RENDERS, on every push (#1030).
    ///
    /// `testDumpEveryMeasuredScreenForReview` below is in `REVIEW_TESTS` and is
    /// skipped by `make test`, correctly: comparing pictures is a judgement no
    /// check can make. But "does this screen render without killing the
    /// process" is a hard pass or fail, and nothing was asking it.
    ///
    /// On 2026-08-29 a change made `PhotoAssignmentView` read an Observable its
    /// renderer did not provide. A missing `@Environment` object is a FATAL
    /// ERROR rather than a failing assertion, so the render died. The full
    /// suite passed 2,565 tests and said nothing, and it was found only by
    /// running `make review-sheet` by hand.
    ///
    /// It rides the SAME `reviewSurfaces` list the sheet is built from, so a
    /// screen added to the sheet is covered here automatically rather than
    /// needing a second registry to be kept in step (L96, L41).
    ///
    /// It writes and compares NOTHING. There is no image to keep, no baseline
    /// to go stale, and no judgement being claimed: the only thing asserted is
    /// that the render happened and produced a surface with pixels in it.
    /// Measured at 1.0s for the whole sheet, which is what makes it affordable
    /// on every push rather than on a person's say so.
    ///
    /// Its registry entry renders one screen at NO SIZE rather than removing an
    /// Observable, and that is deliberate. Removing the Observable was tried
    /// first: it takes the whole test process down, xcodebuild reports zero
    /// tests executed, and `check_guards` correctly refuses to read that as a
    /// kill, because a crash is indistinguishable from the named test never
    /// having run (L154). So the entry proves the half that can be attributed,
    /// that this really does read what each surface rendered, and the crash
    /// half is covered by the render simply happening here at all: nothing else
    /// in `make test` calls these renderers, which is the whole gap #1030 is
    /// about.
    func testEveryReviewSurfaceStillRenders() throws {
        let surfaces = reviewSurfaces

        // A sweep that renders nothing objects to nothing (L98).
        XCTAssertGreaterThan(surfaces.count, 20,
                             "the sheet claims \(surfaces.count) surfaces, which is "
                             + "fewer than this file measures, so this is checking "
                             + "whichever ones happened to be listed")

        for surface in surfaces {
            let rendered = try surface.render()
            XCTAssertGreaterThan(rendered.pixelsWide * rendered.pixelsHigh, 0, """
                "\(surface.name)" rendered a surface with no pixels in it. Reaching \
                here at all means it did not take the app down, so this is a screen \
                that laid out to nothing rather than one that crashed, and either way \
                the picture on the review sheet is of nothing.
                """)
        }
    }

    func testDumpEveryMeasuredScreenForReview() throws {
        let surfaces = reviewSurfaces
        // This group only, so a sibling worker's images survive (#992).
        try ReviewSheet.begin(group: Self.reviewGroup)
        XCTAssertGreaterThan(surfaces.count, 20,
                             "the sheet claims \(surfaces.count) surfaces, which is "
                             + "fewer than this file measures, so it is a review of "
                             + "whichever ones happened to be listed")

        for surface in surfaces {
            try ReviewSheet.write(try surface.render(),
                                  group: Self.reviewGroup, name: surface.name)
        }

        let written = try ReviewSheet.written(group: Self.reviewGroup)
        ReviewSheet.announce(group: Self.reviewGroup, count: written.count)

        XCTAssertEqual(written.count, surfaces.count, """
            \(surfaces.count) surfaces were rendered and \(written.count) reached \
            \(ReviewSheet.folder.path). A sheet missing a screen looks exactly like a \
            sheet of every screen, and the one missing is the one nobody reviews.
            """)
    }

    fileprivate static let reviewGroup = "screens"
}
#endif
