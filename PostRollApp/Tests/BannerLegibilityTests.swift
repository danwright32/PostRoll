import XCTest
import SwiftUI
import AppKit

/// #389: every notice this app shows, rendered and measured, rather than
/// trusted.
///
/// Four new banners shipped on 2026-08-12 and not one was seen before it
/// merged, because reaching those states means filling a disk or breaking a
/// file permission. Copy that reads fine in a test can still land invisible:
/// white on cream has shipped unreadable in this project three separate times,
/// and each time a test asserting the STRING was green throughout.
///
/// So these render the real banner, with the real message produced by the real
/// code, and measure ink on the page. A banner whose text matches its own
/// background produces a near-empty image and fails here.
@MainActor
final class BannerLegibilityTests: XCTestCase {

    /// The share of the page that has to be something other than the fill for
    /// the message to count as drawn.
    ///
    /// Measured, not guessed, and re-measured every time surfaces were added
    /// (#391, #396, #559). With the staleness notice and the rescan offer in,
    /// the thirty-seven real states render between 0.022 and 0.248, and a page
    /// with nothing legible on it renders at 0.001. This sits below the
    /// thinnest real one (a single line of text) and far above blank.
    ///
    /// Ink alone is not the whole answer for a surface that paints a fill: the
    /// rescan offer's 0.248 is mostly its button background, which is there
    /// whatever the label does. `testTheRescanLabelHasReadableContrastAgainstItsFill`
    /// is what covers that half.
    ///
    /// `testTheThinnestRealSurfaceStillClearsTheThresholdWithRoom` is what keeps
    /// that true: adding a surface thinner than this is a failure rather than a
    /// reason to lower the number.
    private static let legibleInk = 0.01

    /// Renders a view and returns its pixels.
    /// No padding around the content: a transparent ring at the edge of the
    /// image is itself a colour that differs from the fill, and at these sizes
    /// it measures as several percent of the page, which is enough to make a
    /// blank render look like a drawn one.
    private func render(_ view: some View, width: CGFloat = 520,
                        wordless: Bool = false) throws -> NSBitmapImageRep {
        // On Color.cream, because that is the surface every one of these sits
        // on in the app. A banner fill is translucent, so rendered against
        // nothing it is mostly transparent and every measurement below would be
        // taken on a page the person never sees.
        //
        // The `.frame(width:)` is load-bearing beyond layout: ImageRenderer
        // draws the text of a view carrying a repeating animation only when it
        // is given a size, so without it every animating surface would render
        // wordless and pass on its own chrome (#612).
        // `HostedControlLegibilityTests.testTheNoticeHarnessRendersIntoAFrame`
        // is what holds that line here.
        try WordFootprint.imageRendered(ZStack {
            Color.cream
            view.padding(Spacing.md)
        }.frame(width: width), wordless: wordless)
    }

    /// Every banner state the app can show, each carrying the message its own
    /// shipping code produces. Nothing here is hand written copy: a preview of
    /// invented text would show something the app never says.
    static var measuredStates: [(name: String, view: AnyView)] { BannerLegibilityTests().states }

    fileprivate var states: [(name: String, view: AnyView)] {
        let refusal = ProgramReadiness.missingFiles([
            URL(fileURLWithPath: "/programs/Gala_p3.png"),
        ]).refusal ?? ""

        let incomplete = ProgramImport.Incomplete(
            fileName: "Gala.pdf",
            pagesThatWorked: (1...9).map { URL(fileURLWithPath: "/programs/Gala_p\($0).png") },
            failures: [.couldNotWritePage(3, reason: "No space left on device")],
            declaredPageCount: 12
        )

        let substitution = PreviewMergePolicy.substitutionNotice([
            PreviewMergePolicy.AbsentApproval(label: "Wednesday collage.png",
                                              fileName: "collage.png"),
        ]) ?? ""

        // The rest of what Dan reads, each from its own shipping code (#391).
        let week: WeekGenerationResult = {
            var w = WeekGenerationResult()
            w.stoppedReason = "Claude usage limit reached"
            // A week that stopped is not complete. PartialWeekMerge enforces
            // that pairing, so a fixture setting only the reason would render a
            // headline the app can never actually show (L48).
            w.complete = false
            w.unrecognisedFailures = ["exit 1: something the cap detector did not know"]
            return w
        }()

        let mediaError = MediaErrorSummary.sentence([
            "wednesday": "collage failed: no such file or directory",
        ]) ?? ""
        let mediaWarning = MediaErrorSummary.warningSentence([
            "thursday": "the chosen black and white photo has moved",
        ]) ?? ""
        let unfamiliar = RunOutcomeNotice.unfamiliarFailureNote(week: week) ?? ""
        let analytics = AnalyticsStore.recoveryText(setAsideAs: "analytics.json.broken",
                                                    restorable: false)
        // The real halt screen needs a real HaltedWeek, built the way the app
        // builds one: from a week that actually stopped.
        // `choices` is the type's own, not passed in, so the screen offers
        // exactly what the app offers.
        let halted = HaltedWeek(reason: "Claude usage limit reached. Your allowance resets at 3pm.",
                                finishedDays: [.sunday, .tuesday])
        let haltedEmpty = HaltedWeek(reason: "Claude usage limit reached. Your allowance resets at 3pm.",
                                     finishedDays: [])

        let missingMedia = MissingMediaBannerText.message(photoCount: 3,
                                                    standaloneNames: ["reel audio"])

        // The four remaining stage screens (#396). Each one's body is now its own
        // view taking plain values, and every message below is produced by the
        // shipping code that produces it in the app.
        // A run that reached the end of the week with two steps dead, and a
        // photo it could not open on a third. Both facts come off the same
        // object the app reads, so the headline, the mark and the cards below
        // cannot be from three different weeks.
        let failedWeek: WeekGenerationResult = {
            var w = WeekGenerationResult()
            w.complete = true
            w.errors = [
                "thursday": "RuntimeError: ffmpeg not found on PATH",
                "blog": "anthropic api error: overloaded_error",
            ]
            w.warnings = ["thursday": [
                SkippedPhoto(file: "DSC_4417.jpg", reason: "could not be opened"),
            ]]
            return w
        }()

        // The clean ending, which is the only one allowed to claim the week
        // finished. A separate fixture rather than the same one read differently,
        // because the difference between these two screens IS the claim.
        let cleanWeek: WeekGenerationResult = {
            var w = WeekGenerationResult()
            w.complete = true
            return w
        }()

        let failureCards = ["blog", "thursday"].map { key in
            let raw = failedWeek.errors[key] ?? ""
            let (text, fixable) = GenerationFailureText.humanize(day: key, raw: raw)
            return GenerationFailureCard(id: key,
                                         label: GenerationFailureText.dayLabel(key),
                                         message: text,
                                         fixable: fixable)
        }

        // A real retry timeline, on the app's own fallback timings, which is what
        // a first run shows before TimingStore has any history.
        let retry = GenerationRunPlan.retryPlan(retryDays: ["thursday", "blog"],
                                                dayCount: 5)

        let ocrIssues = OCRReviewReadiness.detectedIssues(performerCount: 0, pieceCount: 0)

        return [
            ("ocr refusal", AnyView(BrandBanner(
                icon: "exclamationmark.triangle", message: refusal, style: .error,
                actions: [BrandBannerAction(label: "Dismiss") {}]))),
            ("incomplete upload", AnyView(BrandBanner(
                icon: "exclamationmark.triangle", message: incomplete.message, style: .error,
                actions: [BrandBannerAction(label: "Import the 9 pages that worked") {},
                          BrandBannerAction(label: "Dismiss") {}]))),
            ("partial program", AnyView(BrandBanner(
                icon: "doc.badge.ellipsis",
                message: ProgramShortfall.acceptanceNote(for: incomplete), style: .warning))),
            ("export substitution", AnyView(BrandBanner(
                icon: "exclamationmark.triangle", message: substitution, style: .warning))),
            ("upload reminder", AnyView(BrandBanner(
                icon: "arrow.down.circle",
                message: "Download the program from your browser first."))),
            ("export failure", AnyView(BrandBanner(
                icon: "exclamationmark.triangle", message: mediaError, style: .error))),
            ("export warning", AnyView(BrandBanner(
                icon: "exclamationmark.triangle", message: mediaWarning, style: .warning))),
            ("unfamiliar failure", AnyView(BrandBanner(
                icon: "questionmark.circle", message: unfamiliar, style: .warning))),
            ("save failure", AnyView(BrandBanner(
                icon: "exclamationmark.triangle.fill",
                message: SaveFailureNotice.message(reason: "The volume is out of space."),
                style: .error,
                actions: [BrandBannerAction(label: SaveFailureNotice.retryLabel, action: {})]))),
            ("analytics recovery", AnyView(BrandBanner(
                icon: "chart.bar", message: analytics, style: .error))),
            ("missing media", AnyView(BrandBanner(
                icon: "photo", message: missingMedia, style: .warning))),
            // A whole screen, not a message in a stand-in container (#393).
            // Both endings, because the difference between them is the claim
            // that the event was archived, and only one of them is true.
            ("export done, complete", AnyView(ExportDoneSummary(
                folderName: "2026-08-12 Spring Gala",
                mediaError: nil,
                mediaWarning: mediaWarning))),
            ("export done, incomplete", AnyView(ExportDoneSummary(
                folderName: "2026-08-12 Spring Gala",
                mediaError: mediaError,
                mediaWarning: nil))),
            // The real halt screen body, both shapes: a run that saved some
            // days and one that saved none, because the sentence about what
            // survived is the whole point of the screen.
            ("halt screen, some days saved", AnyView(HaltedWeekBody(halted: halted))),
            ("halt screen, nothing saved", AnyView(HaltedWeekBody(halted: haltedEmpty))),

            // Generation, all four of its screens (#396).
            ("generation configure, ready", AnyView(GenerationConfigureBody(
                daysCount: 5, totalPhotos: 48, hasBlog: true))),
            // The state that refuses to start. Its sentence is the only thing
            // explaining the disabled button beside it.
            ("generation configure, no photos", AnyView(GenerationConfigureBody(
                daysCount: 0, totalPhotos: 0, hasBlog: false))),
            ("generation running, retry", AnyView(GenerationRunningBody(
                eventName: "Spring Gala",
                subtitle: GenerationRunPlan.subtitle(retryDays: ["thursday", "blog"],
                                                     dayCount: 5),
                phases: retry?.phases ?? [],
                activePhaseIndex: 1,
                elapsedFormatted: "1:12",
                estimatedTotalFormatted: TimingStore.formatClock(retry?.estimate ?? 0)))),
            ("generation failed", AnyView(GenerationErrorBody(
                message: "The run died: exit 1. See the log for what Python reported.",
                hasPreviousResults: true))),
            // A finished run and a finished run with failures are different
            // screens, and only one of them may claim the week is done.
            ("generation done, clean", AnyView(GenerationDoneBody(
                eventName: "Spring Gala",
                headline: RunOutcomeNotice.headline(week: cleanWeek, failedDayCount: 0),
                isUnqualifiedSuccess: RunOutcomeNotice.isUnqualifiedSuccess(
                    week: cleanWeek, failedDayCount: 0),
                // No regenerable days on purpose: that control is a `Menu`, and
                // ImageRenderer cannot draw one. See
                // testTheUnrenderableControlsAreNamedRatherThanMeasured.
                programPDFLabel: "Download program PDF",
                hasBlog: true))),
            ("generation done, with failures", AnyView(GenerationDoneBody(
                eventName: "Spring Gala",
                headline: RunOutcomeNotice.headline(week: failedWeek, failedDayCount: 2),
                isUnqualifiedSuccess: RunOutcomeNotice.isUnqualifiedSuccess(
                    week: failedWeek, failedDayCount: 2),
                unfamiliarNote: unfamiliar,
                failures: failureCards,
                programPDFLabel: "Building program PDF…",
                programPDFDisabled: true,
                programBakeError: "The page scans could not be read.",
                hasBlog: true))),

            // Caption review's bottom bar and its notices (#396).
            ("caption bar, ready", AnyView(CaptionReviewActionBar(
                activity: .ready(graphicsError: nil)))),
            ("caption bar, graphics failed", AnyView(CaptionReviewActionBar(
                activity: .ready(graphicsError:
                    "collage failed: no such file or directory")))),
            // This one carries a ProgressView, which ImageRenderer draws as a
            // placeholder. Kept anyway because its two sentences are the point and
            // they dominate the measurement; see
            // testTheUnrenderableControlsAreNamedRatherThanMeasured.
            ("caption bar, waiting on rebuild", AnyView(CaptionReviewActionBar(
                activity: .waitingOnRebuild(reason: ExportReadiness.blockedReason(
                    regeneratingDays: [.thursday, .wednesday]) ?? "")))),
            ("caption notices", AnyView(CaptionReviewNotices(
                failedDayCount: failedWeek.errorCount,
                regenerateError: "Regeneration failed: exit 1",
                skippedPhotoNotices: DayName.allCases.compactMap { day in
                    failedWeek.warningMessage(for: day).map {
                        CaptionReviewDayNotice(id: day.rawValue,
                                               message: "\(day.displayName): \($0)")
                    }
                },
                mediaWarnings: [CaptionReviewDayNotice(
                    id: "tuesday",
                    message: "Tuesday: the chosen black and white photo has moved")]))),

            // OCR review's notices and the bar that ends it (#396).
            ("ocr notices, all five", AnyView(OCRReviewNotices(
                detectedIssues: ocrIssues,
                partialProgramNotes: [ProgramShortfall.acceptanceNote(for: incomplete)],
                visionSkippedMessage: OCRReviewReadiness.visionSkippedMessage(
                    "The program pages were too large to read."),
                webPerformersSkippedMessage:
                    OCRReviewReadiness.webPerformersSkippedMessage("the request timed out"),
                flagErrorMessage: OCRReviewReadiness.flagErrorMessage(
                    "connection reset by peer")))),
            // The bar that refuses, with its reason drawn rather than only in a
            // tooltip, which is the whole point of measuring ink on it.
            ("ocr bar, blocked", AnyView(OCRConfirmBar(
                label: OCRReviewReadiness.confirmLabel(unresolvedFlagCount: 3,
                                                       hasDetectedIssues: true),
                help: OCRReviewReadiness.confirmHelp(unresolvedFlagCount: 3,
                                                     hasDetectedIssues: true),
                unresolvedFlagCount: 3))),
            ("ocr bar, thin data", AnyView(OCRConfirmBar(
                label: OCRReviewReadiness.confirmLabel(unresolvedFlagCount: 0,
                                                       hasDetectedIssues: true),
                help: OCRReviewReadiness.confirmHelp(unresolvedFlagCount: 0,
                                                     hasDetectedIssues: true),
                unresolvedFlagCount: 0))),

            // Photo assignment (#396). The missing-media state needed a photo to
            // actually go missing off disk before anyone could look at it.
            ("photo notices, missing media", AnyView(PhotoAssignmentNotices(
                importResult: "Imported 42 photos across 5 days.",
                missingPhotoCount: 3,
                missingStandaloneNames: ["Tuesday B&W photo"]))),
            ("photo notices, import failed", AnyView(PhotoAssignmentNotices(
                importResult: "No day subfolders found in that folder.",
                importFailed: true))),
            ("photo continue bar, no photos", AnyView(
                PhotoAssignmentContinueBar(totalPhotos: 0))),
            ("photo continue bar, ready", AnyView(
                PhotoAssignmentContinueBar(totalPhotos: 48))),

            // The two refusals that used to be unreadable (#402): one delivered
            // only on hover, one never computed at all. Both messages come from
            // the code that decides the gate, so a wording change moves what is
            // measured here rather than leaving this asserting a stale copy.
            ("stage strip refusal, no program", AnyView(RefusalNote(
                message: StageNavigation.blockedReason(
                    for: .assetsGenerated,
                    in: Event(name: "Spring Gala", org: "Ballet", venue: "City Center",
                              date: Date(), shootType: .fullShow)) ?? ""))),
            ("new event refusal, nothing filled in", AnyView(RefusalNote(
                message: NewEventValidation.refusal(name: "", org: "") ?? ""))),

            // Two surfaces that shipped with nothing rendering them (#559).
            // Both had a source scan asserting the screen references the shared
            // rule, which proves the call site exists and cannot notice a
            // control drawn off screen, at zero height, or in the colour behind
            // it.
            //
            // The staleness notice says the numbers on screen predate the
            // timezone correction (#549). Its sentence comes from
            // AnalyticsStaleness, so a rewording moves what is measured here
            // rather than leaving this asserting a stale copy.
            ("insights staleness notice", AnyView(AnalyticsStalenessNotice())),

            // The rescan offer (#518), in both of its states. The refusal is
            // the one that matters most: it is the branch Dan meets when a page
            // in the gap has gone, and it is a different view from the button.
            ("ocr rescan offer", AnyView(OCRReviewNotices(
                rescan: OCRReviewNotices.RescanOffer(
                    title: OCRRescan.buttonTitle(pageCount: 2),
                    refusal: nil,
                    note: nil,
                    isRunning: false,
                    action: {})))),
            ("ocr rescan refused", AnyView(OCRReviewNotices(
                rescan: OCRReviewNotices.RescanOffer(
                    title: OCRRescan.buttonTitle(pageCount: 1),
                    refusal: OCRRescan.message(
                        for: [("/programs/Gala_p3.png", .missing)]),
                    note: nil,
                    isRunning: false,
                    action: {})))),
            // Running, with a page the programme no longer has a position for
            // left out of it (#575). The note and the live button are on screen
            // together, which is the state the pages left behind are reported
            // in, so it has to be readable rather than only reachable.
            ("ocr rescan leaving a page behind", AnyView(OCRReviewNotices(
                rescan: OCRReviewNotices.RescanOffer(
                    title: OCRRescan.buttonTitle(pageCount: 1),
                    refusal: nil,
                    note: OCRRescan.plan(for: [
                        OCRRescan.Page(number: nil, path: "/programs/Gala_insert.png"),
                    ]).refusal,
                    isRunning: false,
                    action: {})))),
        ]
    }

    /// Every surface here puts its words on the page (#396, #612, #614).
    ///
    /// This asked for a share of the render to be INK until #614. Ink is the
    /// share of pixels unlike the commonest colour, so it counts the fill, the
    /// border, the icon and the button along with the type, and a notice is
    /// mostly those: the rescan offer measured 0.2477 while almost all of it was
    /// a button's own background. That is L141 in the check built to catch L141.
    ///
    /// Now each state is rendered twice, once as it ships and once with its type
    /// switched off, and what is measured is the difference. Nothing about the
    /// chrome is in that number.
    ///
    /// The floor comes from `WordFootprint` and is one number for every surface
    /// in the suite, which is what #614 was about: three thresholds had grown
    /// here, 0.01 for a notice and 0.005 twice for a sparser screen, each
    /// honestly measured against its own surface and each lower than the last.
    func testEveryBannerActuallyDrawsItsMessage() throws {
        // A sweep that reads nothing objects to nothing (L98).
        XCTAssertGreaterThan(states.count, 30,
                             "the sweep found \(states.count) states, so it is proving "
                             + "nothing about the ones it did not draw")

        for state in states {
            let share = WordFootprint.share(try render(state.view),
                                            try render(state.view, wordless: true))
            XCTAssertGreaterThan(share, WordFootprint.drawn, """
                Switching every word off the "\(state.name)" banner changed \
                \(String(format: "%.4f", share)) of the render, which is nothing. Its \
                message is in the view tree and not on the screen, and the fill, the \
                border and the buttons this surface paints for itself would keep a flat \
                ink threshold happy without it (L141). Either the words are drawn in the \
                colour of what is behind them, or ImageRenderer is not drawing them at \
                all, in which case the state belongs in HostedControlLegibilityTests \
                where AppKit hosts it.
                """)
        }
    }

    /// What each surface's words are actually worth, so the floor stays a
    /// measured number rather than one carried forward on faith (#396).
    ///
    /// Printed rather than asserted per surface: pinning each figure would fail on
    /// every legitimate wording change, which is a guard asserting a rendering
    /// instead of the rule behind it (L103). What IS asserted is the property the
    /// floor depends on, that the thinnest real surface still clears it with
    /// room, so adding a screen cannot quietly drag the band down onto blank.
    func testTheThinnestRealSurfaceStillClearsTheThresholdWithRoom() throws {
        var measured: [(String, Double)] = []
        for state in states {
            measured.append((state.name,
                             WordFootprint.share(try render(state.view),
                                                 try render(state.view, wordless: true))))
        }
        let sorted = measured.sorted { $0.1 < $1.1 }
        for (name, share) in sorted {
            print(String(format: "  %.4f  %@", share, name))
        }

        let thinnest = try XCTUnwrap(sorted.first)
        XCTAssertGreaterThan(thinnest.1, WordFootprint.drawn * 5, """
            "\(thinnest.0)" measures \(String(format: "%.4f", thinnest.1)), which is \
            close enough to the \(WordFootprint.drawn) floor that the check above can \
            no longer tell a thin surface from a blank one. Re-measure the floor \
            against the real band rather than lowering it.
            """)
    }

    /// A banner is worth nothing if the words run past the edge of it. Rendering
    /// at a narrow width is where a long message with a two button row breaks.
    func testEveryBannerStillDrawsItsMessageWhenNarrow() throws {
        for state in states {
            let share = WordFootprint.share(
                try render(state.view, width: 300),
                try render(state.view, width: 300, wordless: true))
            XCTAssertGreaterThan(share, WordFootprint.drawn,
                                 "the \"\(state.name)\" banner lost its message at 300pt wide")
        }
    }

    /// Two controls this harness cannot draw, named here rather than left to be
    /// rediscovered (#396).
    ///
    /// `ImageRenderer` has no AppKit host, so `Menu` and `ProgressView` come out as
    /// a bright placeholder block instead of themselves. That block is a colour
    /// unlike the fill, so it MEASURES AS INK: a state consisting of one of these
    /// and nothing else would sail through every check above while showing the
    /// reader nothing. This proves that is what happens, which is why the two
    /// affected states are built without their menu and why the one that keeps its
    /// spinner carries real sentences beside it.
    /// The other half of that, and the one #559 turns on: a `Button` IS drawn,
    /// so measuring one means something.
    ///
    /// Checked rather than assumed, because the rescan offer is a button and
    /// nothing else. If `ImageRenderer` substituted a placeholder for it the way
    /// it does for `Menu`, that state would clear every threshold above while
    /// showing no words, and the check would report hardest on the surface it
    /// could see least of (L115).
    ///
    /// The proof is the same one the metric itself gets: one view rendered
    /// twice, differing only in whether its type is visible. A placeholder
    /// cannot tell those apart, so equal readings would mean this harness is
    /// not reading the button's words at all.
    func testABareButtonIsDrawnRatherThanSubstituted() throws {
        func button(_ colour: Color) -> some View {
            ZStack {
                Color.cream
                Button("Scan the 2 pages that were missed") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(colour)
            }
            .frame(height: 60)
        }

        func share(_ colour: Color) throws -> Double {
            WordFootprint.share(try render(button(colour)),
                                try render(button(colour), wordless: true))
        }
        let invisible = try share(.cream)
        let legible = try share(.warmDark)

        XCTAssertLessThan(invisible, WordFootprint.drawn, """
            A button whose label is drawn in its own background colour measured \
            \(String(format: "%.4f", invisible)) as a footprint, so something other \
            than its words is moving when the type is taken away. If ImageRenderer has \
            started substituting a placeholder for Button the way it does for Menu, the \
            rescan offer below is being measured on that block rather than on anything \
            readable.
            """)
        XCTAssertGreaterThan(legible, WordFootprint.drawn * 5,
                             "the same button label in a readable colour has to be worth "
                             + "far more than the floor, or its words are not being drawn")
    }

    /// Ink is not the whole answer for a control that paints a fill (#559).
    ///
    /// The rescan offer measures 0.2475, and almost all of that is the button's
    /// rose gold background, which is on the page whatever the label does. So
    /// the ink check would clear on a button whose words were drawn in the fill
    /// colour, which is the defect that has shipped here three times. The
    /// contrast between the two colours is the part that says the label can be
    /// read, and both come from the shipping style rather than from numbers
    /// typed in here.
    ///
    /// The floor is 4.5:1, which is what WCAG AA asks for body-sized text, and
    /// the label is 13pt medium. It measures 5.05:1, so the margin above the
    /// floor is real rather than a rounding: a later wording or weight change
    /// cannot quietly drop it back under (#569).
    func testTheRescanLabelHasReadableContrastAgainstItsFill() throws {
        let pair = try surface("primary button", "label")
        let ratio = contrastRatio(pair.foreground, pair.background)

        XCTAssertGreaterThan(ratio, pair.kind.floor, """
            The primary button draws its label at \(String(format: "%.2f", ratio)):1 \
            against its own fill, which is below the level at which a control's \
            text can be relied on to be readable. A button whose words match the \
            colour behind them still measures as ink, because the fill is what is \
            being measured.
            """)
    }

    /// The pair for one element of one surface, from the shipping list.
    private func surface(_ name: String, _ element: String) throws -> PaintedSurfaces.Pair {
        try XCTUnwrap(PaintedSurfaces.all.first { $0.surface == name && $0.element == element },
                      "\(name) / \(element) is not in PaintedSurfaces.all, so nothing "
                      + "is reading its colours against what is behind them")
    }

    // MARK: - Every surface, not just two (#574)
    //
    // Ink over a whole surface is answered by whatever that surface paints for
    // ITSELF: a panel, a border, a button fill. So the words it exists to check
    // can be drawn in the colour behind them while the measurement barely moves.
    // Proved by mutation during #559, where the Insights staleness notice's
    // sentence drawn in its own panel colour still measured 0.0799 against a
    // 0.01 threshold and the guard SURVIVED (L141).
    //
    // #559 closed that for two surfaces. This closes it for the rest: every
    // surface that paints something behind its type names the pair in
    // PaintedSurfaces, the views draw from those names, and this reads the same
    // values rather than a copy that could only confirm itself (L70).

    func testEverySurfaceIsReadableAgainstWhatIsBehindIt() throws {
        for pair in PaintedSurfaces.all {
            let ratio = contrastRatio(pair.foreground, pair.background)
            XCTAssertGreaterThan(ratio, pair.kind.floor, """
                The "\(pair.surface)" \(pair.element) is drawn at \
                \(String(format: "%.2f", ratio)):1 against the colour behind it, \
                under the \(pair.kind.floor):1 it needs. Ink on that surface cannot \
                report this: the fill, the panel and the border are marks on the \
                page whatever the words do.
                """)
        }
    }

    /// Every banner style, taken from the type rather than from a list here, so
    /// a fourth one cannot arrive with nobody reading its colours (L113).
    func testEveryBannerStyleIsCovered() {
        for style in BrandBannerStyle.allCases {
            XCTAssertTrue(PaintedSurfaces.all.contains { $0.surface == "banner \(style)" },
                          "banner \(style) paints a fill that nothing checks the "
                          + "words against")
        }
    }

    /// Every stage pill state, taken from the type rather than from a list
    /// here, so an eighth stage cannot arrive with nobody reading its colours
    /// (#582, L113).
    ///
    /// This is per state and not per family on purpose. The pill's wash is its
    /// own colour, so each state is a different measurement: the seven stages
    /// ran from 2.42:1 to 3.67:1, and judging the family on one sample would
    /// have reported whichever one was picked.
    func testEveryStagePillStateIsCovered() {
        for state in StagePillState.allPillStates {
            XCTAssertTrue(PaintedSurfaces.all.contains { $0.surface == "stage pill \(state)" },
                          "the \(state) pill draws a wash with its own label on it and "
                          + "nothing checks the two against each other")
        }
    }

    /// The selected pill's colours are pinned, not whatever is current (#587).
    ///
    /// `Color.primary` is a dynamic colour: read under one appearance it is
    /// near-black, under another it is near-white. If the pinning quietly did
    /// nothing, this pair would be measuring the appearance the TEST process
    /// happens to have, agree with itself, and say nothing about the app. So
    /// the same colour is resolved under the opposite appearance and the two
    /// have to differ, which they only can if the pin binds (L70).
    /// Every name built from a system colour, not just the pill's (#590). The
    /// row's detail lines are resolved the same way and would fail the same
    /// way, so they are held to the same proof rather than trusted to the
    /// helper they share.
    func testTheSelectedPillIsMeasuredUnderTheAppearanceTheAppPins() throws {
        var underDark: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            underDark = NSColor(Color.primary).usingColorSpace(.sRGB)
        }
        let dark = try XCTUnwrap(underDark, "the opposite appearance did not resolve")

        for (name, colour) in [("selected pill label", PaintedSurfaces.selectedPillLabel),
                               ("selected row detail lines",
                                PaintedSurfaces.eventRowDetailSelected)] {
            let pinned = try XCTUnwrap(NSColor(colour).usingColorSpace(.sRGB))

            XCTAssertNotEqual(pinned.brightnessComponent, dark.brightnessComponent,
                              accuracy: 0.01,
                              "the \(name) resolves to the same colour under both "
                              + "appearances, so it is not pinned to the one the app "
                              + "forces and this pair is measuring whatever is current "
                              + "here")
            XCTAssertLessThan(pinned.brightnessComponent, 0.5,
                              "the app pins itself to light, where the \(name) is dark. "
                              + "A light one here means this resolved under the wrong "
                              + "appearance and the ratio is against a colour the app "
                              + "never draws")
        }
    }

    /// The event row draws every word from a named pair (#590).
    ///
    /// Built is not wired (L3). The three pairs above are read from
    /// `PaintedSurfaces`, so a row that went back to `Color.secondary` would
    /// leave them measuring a palette the list had stopped using, and a system
    /// colour is exactly what nothing here can reach: it is not in the palette,
    /// so no pair covers it and the ratio walk has nothing to say.
    ///
    /// What this asserts is the WIRING half only. Banning the system colours it
    /// went back to is now one rule over the whole tree
    /// (`testNoScreenDrawsTypeInASystemColour`, #598) rather than a copy per
    /// screen, since a scoped copy leaves the next screen exempt by default
    /// (L96). Scoped to the row's own declaration for the half that is still
    /// about the row (L135), and comments are stripped, because the row
    /// explains this rule in prose right beside the code (L103).
    func testTheEventRowDrawsEveryWordFromANamedPair() throws {
        let row = try eventRowDeclaration()

        for name in ["bodyText", "eventRowNameSelected",
                     "secondaryText", "eventRowDetailSelected"] {
            XCTAssertTrue(row.contains("PaintedSurfaces.\(name)"), """
                EventRow no longer draws from PaintedSurfaces.\(name), so that pair is \
                measuring a colour the list does not use and says nothing about what is \
                on screen.
                """)
        }
    }

    /// The Settings window's own words are named too (#596).
    ///
    /// The same rule as the row above, one screen further out. The footers
    /// under each section are where the app explains what a setting does, and
    /// they were the platform's `.secondary`, which is the label colour at half
    /// strength: 3.95:1 on the white a form is drawn on, under the 4.5:1 an
    /// 11pt line needs. Nothing could report it, because a system colour on
    /// system chrome is named by neither side.
    ///
    /// The three state labels in the same window went the same way (#598), so
    /// this asserts the wiring for all four names. The ban on going back to the
    /// platform's colours is one rule over the whole tree rather than a copy
    /// here, for the reason above.
    func testTheSettingsFormDrawsItsWordsFromANamedPair() throws {
        let code = try appSource("Sources/Views/SettingsView.swift")

        for name in ["readableSecondaryLabel", "stateWarningText",
                     "stateSuccessText", "stateErrorText"] {
            XCTAssertTrue(code.contains("PaintedSurfaces.\(name)"), """
                SettingsView no longer draws from PaintedSurfaces.\(name), so the pair \
                for that window is measuring a colour it does not use. That window is \
                where the app says a pasted key is the wrong shape, whether it saved, \
                and why it refused.
                """)
        }
    }

    /// The source of `EventRow` alone, comments stripped.
    ///
    /// Bounded by the next type declaration rather than by a line count, so
    /// adding a line to the row cannot quietly push half of it out of the
    /// scope this reads.
    private func eventRowDeclaration() throws -> String {
        let code = try appSource("Sources/Views/EventListView.swift")
        let start = try XCTUnwrap(code.range(of: "struct EventRow: View {"),
                                  "EventRow has been renamed or moved out of "
                                  + "EventListView.swift, so this guard is reading a "
                                  + "declaration that no longer exists")
        let rest = code[start.upperBound...]
        let end = rest.range(of: "\nstruct ") ?? rest.range(of: "\nprivate struct ")
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }

    /// The scope above really is the row and not the whole file (#590).
    ///
    /// A range that silently ran to the end of the file would be answered by
    /// any of the other views in it, which is the failure L135 is about, and it
    /// would look exactly like this one passing.
    func testTheEventRowScopeStopsAtTheRow() throws {
        let row = try eventRowDeclaration()
        let file = try appSource("Sources/Views/EventListView.swift")

        XCTAssertTrue(row.contains("event.displayDate"),
                      "the scope no longer holds the row's own lines, so the guard "
                      + "above is reading the wrong region")
        XCTAssertFalse(row.contains("struct UndoBanner"),
                       "the scope runs past the row into the rest of the file, so any "
                       + "other view in it can answer for the row")
        XCTAssertLessThan(row.count, file.count / 2,
                          "the scope is most of the file rather than one declaration")
    }

    /// The pill's wash and its ink are two different colours (#582).
    ///
    /// They were one, drawn as both the fill and the type on that fill, which
    /// is the shape this whole file exists for. If a state ever returns the
    /// same colour twice the ratio walk still passes at 1:1 for the pair
    /// composited over the row, because a 14% wash of a colour is not that
    /// colour, so the walk alone cannot say this went back.
    func testNoStagePillDrawsItsLabelInItsOwnWash() {
        for state in StagePillState.allPillStates {
            let pill = PaintedSurfaces.stagePill(state)
            XCTAssertNotEqual(NSColor(pill.wash.composited(over: PaintedSurfaces.eventRowAtRest)),
                              NSColor(pill.ink),
                              "the \(state) pill draws its label in the colour of its "
                              + "own wash")
        }
    }

    /// The measurement has to be able to fail, or every ratio above is
    /// decoration (L1). Type drawn in the colour behind it is exactly 1:1, and
    /// that is the defect this whole file exists for.
    func testTheRatioReportsTypeDrawnInItsOwnBackgroundAsUnreadable() {
        for pair in PaintedSurfaces.all {
            XCTAssertEqual(contrastRatio(pair.background, pair.background), 1.0,
                           accuracy: 0.0001,
                           "the ratio does not report \"\(pair.surface)\" drawn in its "
                           + "own background colour as unreadable, so it cannot fail "
                           + "for the one reason it exists")
        }
    }

    /// A translucent fill is not the colour behind the words, so a pair judged
    /// against the fill as DECLARED is judged against a colour nothing draws.
    /// The banner fills are washes at 7% to 10%; read raw they are almost the
    /// accent itself, and the ratios would come out on the wrong side.
    func testATranslucentFillIsJudgedAsItLandsRatherThanAsItIsDeclared() {
        let declared = contrastRatio(BrandBanner.text, BrandBanner.fill(.warning))
        let asDrawn = contrastRatio(BrandBanner.text, BrandBanner.background(.warning))

        XCTAssertNotEqual(declared, asDrawn, accuracy: 0.01,
                          "the banner's fill is being read raw, so every banner ratio "
                          + "is computed against a colour that is never drawn")
        XCTAssertGreaterThan(asDrawn, declared,
                             "compositing the wash over the page has to lighten what is "
                             + "behind the words, or the composite is wrong")
    }

    /// Built is not wired (L3). Names that the views do not draw from would let
    /// this file assert a palette the app has stopped using, which is the same
    /// self-confirming check the pairs exist to avoid. Comments are stripped,
    /// because these files explain the naming in prose right beside the code
    /// (L103), and each assertion is scoped to the file it is about (L135).
    ///
    /// Every view file, not the five #574 named (#582). A list of the files
    /// somebody had thought about is exactly the list a new painted surface is
    /// missing from, and seventeen other files were painting fills nothing
    /// could read the words against, including the stage pill: seven washes of
    /// a colour with that same colour as the label on them, between 2.42:1 and
    /// 3.67:1, under a design note claiming they were calibrated for it (L96).
    func testEveryPaintedFileDrawsFromTheNamedColours() throws {
        let files = try everySourceFile()

        // A sweep that reads nothing objects to nothing (L98). The five-file
        // version of this could not have told you it had gone blind either.
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep read \(files.count) source files, so it is proving "
                             + "nothing about the ones it did not open")

        for relative in files {
            let code = try appSource("Sources/\(relative)")

            // The two spellings where the colour is an argument to a painting
            // modifier. Read per line rather than over the whole file, so the
            // failure names the line and so a colour reached through a ternary
            // or built from numbers is caught too (#600): the first version
            // looked for the literal text ".background(Color." and a condition
            // between the bracket and the colour was enough to walk past it.
            for (number, line) in unnamedFills(in: code) {
                XCTFail("""
                    \(relative):\(number) paints from a colour written at the point of \
                    use. Nothing can check the words against it, because nothing else \
                    can name it. Add it to PaintedSurfaces and draw from there.

                    \(line)
                    """)
            }

            // The third spelling (#586). A colour is a view in its own right, so
            // it paints an area with no modifier around it at all, and neither
            // check above can express that. Seven placeholders were drawn this
            // way while this file reported a clean sweep over the same screens,
            // which is worse than not checking them: an unreadable spelling and
            // an absent surface look identical from here.
            for (number, line) in bareColourViews(in: code) {
                XCTFail("""
                    \(relative):\(number) paints an area by using a colour as a view, \
                    which is the same unnamed surface the two checks above refuse in \
                    their own spellings. Add it to PaintedSurfaces and draw from there.

                    \(line)
                    """)
            }
        }
    }

    /// Lines painting a background or a shape from a colour written there.
    ///
    /// A line offends when it calls one of the two painting modifiers AND
    /// mentions a colour by value: `Color.<token>`, or one built from literal
    /// components. `PaintedSurfaces.x`, a local, or a computed pair mention no
    /// colour and pass.
    ///
    /// `Color.clear` is excluded because it paints nothing: it is a spacer and
    /// a hit area, with no surface behind any words. Excluded by name here so
    /// the exemption is one decision written down once (L129).
    private func unnamedFills(in code: String) -> [(Int, String)] {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                // The two painting modifiers, plus the four that draw a LINE or
                // a shadow rather than an area (#628). A border is still exempt
                // from the contrast level, for the reason written over the pair
                // list, but exempt from being MEASURED is not exempt from being
                // named: 31 of these were colours written at the point of use,
                // where nothing else can say what they are or notice one
                // changing. The fill rule had covered the two spellings that
                // fill an area and read as though it covered the rest.
                guard [".background(", ".fill(", ".stroke(",
                       ".strokeBorder(", ".border(", ".shadow("]
                        .contains(where: line.contains) else {
                    return nil
                }
                let mentionsAColour = line.range(of: #"Color\.[A-Za-z]"#,
                                                 options: .regularExpression) != nil
                    || line.range(of: #"Color\(\s*(red|white|hue|nsColor|\.)"#,
                                  options: .regularExpression) != nil
                guard mentionsAColour, !line.contains("Color.clear") else { return nil }
                return (index + 1, line)
            }
    }

    /// The fill matcher is asked directly what it can see (#600, L1).
    ///
    /// The tree is clean, so a matcher that sees one spelling and one that sees
    /// three give the same silent pass, which is how two of these shipped
    /// looking like a rule that held. The same proof
    /// `testTheColourAsAViewMatcherSeesEverySpelling` gets, for the two
    /// spellings it does not cover.
    func testTheUnnamedFillMatcherSeesEverySpelling() {
        let mustCatch = [
            "            .background(Color.creamDeep)",
            "            .fill(Color.roseGold.opacity(0.12))",
            "            .background(Color(red: 0.10, green: 0.09, blue: 0.08))",
            "                    Color(white: 0.92)",
            "            .background(isDragging ? Color.roseGold : Color.black.opacity(0.65))",
            "                Capsule().fill((stale ? Color.warmMid : Color.roseDeep).opacity(0.12))",
            "            .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.22)],",
            // The four that draw a line or a shadow rather than an area (#628).
            // These were outside the rule entirely, and 31 borders had been
            // written at the point of use while this check read as covering
            // every painted surface in the app.
            "                .strokeBorder(Color.creamEdge, lineWidth: 1)",
            "                .stroke(Color.warmMid.opacity(0.2), lineWidth: 1)",
            "        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 2)",
            "            .border(Color.roseGold)",
            "            .strokeBorder(isSelected ? Color.roseGold : Color.creamEdge, lineWidth: 1)",
        ]
        for line in mustCatch {
            let hits = unnamedFills(in: line).count + bareColourViews(in: line).count
            XCTAssertEqual(hits, 1, """
                the check cannot see \(line.trimmingCharacters(in: .whitespaces)) as a \
                painted surface written at the point of use, so a fill spelled that way \
                is exempt from the rule and reads exactly like no fill at all
                """)
        }

        let mustAllow = [
            "            .background(PaintedSurfaces.page)",
            "            .fill(pill.wash)",
            "            .background(isSelected ? PaintedSurfaces.selectedPillFill : pill.wash)",
            "            .fill(PaintedSurfaces.captionFindings(stale: stale).panel)",
            "            .background(Color.clear)",
            "            .foregroundStyle(Color.warmDark)",
            "                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)",
            "                .stroke(PaintedSurfaces.accentBorder.opacity(0.2), lineWidth: 1)",
            "    static let creamDeep = Color(red: 237/255, green: 232/255, blue: 224/255)",
        ]
        for line in mustAllow {
            let hits = unnamedFills(in: line).count + bareColourViews(in: line).count
            XCTAssertEqual(hits, 0, """
                the check reports \(line.trimmingCharacters(in: .whitespaces)) as an \
                unnamed painted surface, which it is not. A rule that fires on correct \
                code is the rule people learn to work around
                """)
        }
    }

    /// Lines where a colour is used as a view, with its 1-based line number.
    ///
    /// Matches the colour at the START of the line and lets anything follow,
    /// because a painted area routinely carries its modifiers on the same line
    /// (`Color.creamDeep.overlay { … }`, `Color.cream.ignoresSafeArea()`).
    ///
    /// The first version of this ended the pattern at the line break, so it saw
    /// the ten sites written with nothing after the colour and none of the
    /// thirteen written with a modifier. Every one of those thirteen had
    /// already been named by hand, so the whole suite was green and the check
    /// looked like it worked: it was `check_guards` putting one site back that
    /// showed it had never been protecting them (L1).
    ///
    /// `Color.clear` is excluded because it paints nothing: it is a spacer and
    /// a hit area, and there is no surface behind any words. Excluded here by
    /// name rather than by the caller skipping it, so the exemption is one
    /// decision written down once (L129).
    private func bareColourViews(in code: String) -> [(Int, String)] {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                // A named colour, or one built from literal components (#600):
                // the placeholder square inside the Instagram card was
                // `Color(white: 0.92)` on a line of its own, which is this
                // spelling and this rule, and the pattern could not say so.
                guard line.range(of: #"^Color(\.[A-Za-z][A-Za-z0-9]*\b|\(\s*(red|white|hue)\b)"#,
                                 options: .regularExpression) != nil,
                      !line.hasPrefix("Color.clear") else { return nil }
                return (index + 1, line)
            }
    }

    /// The detector above is asked directly what it can see (#586).
    ///
    /// Running it over the real tree cannot answer this. The tree is clean, so
    /// a detector that sees one spelling and a detector that sees both give the
    /// same silent pass, and the narrow one shipped looking correct. A guard is
    /// only real once it has been seen to fail, and the thing that has to fail
    /// is the matcher, not the codebase around it (L1).
    func testTheColourAsAViewMatcherSeesEverySpelling() {
        let mustCatch = [
            "        Color.creamDeep",
            "        Color.creamDeep.overlay { Text(\"x\") }",
            "        Color.cream.ignoresSafeArea()",
            "        Color.creamEdge.frame(height: 0.5)",
            "        Color.black.opacity(0.4)",
        ]
        for line in mustCatch {
            XCTAssertEqual(bareColourViews(in: line).count, 1, """
                the check cannot see \(line.trimmingCharacters(in: .whitespaces)) as a \
                painted area, so a surface written that way is exempt from it and \
                reads exactly like no surface at all
                """)
        }

        let mustAllow = [
            "        Color.clear",
            "        Color.clear.frame(width: 8)",
            "        .background(PaintedSurfaces.page)",
            "        .foregroundStyle(Color.warmDark)",
            "        let x = Color.roseGold",
        ]
        for line in mustAllow {
            XCTAssertEqual(bareColourViews(in: line).count, 0, """
                the check reports \(line.trimmingCharacters(in: .whitespaces)) as an \
                unnamed painted area, which it is not. A rule that fires on correct \
                code is the rule people learn to work around
                """)
        }
    }

    /// The accent may not be drawn without saying which role it is in (#580).
    ///
    /// `roseGold` measures 4.31:1 on the page and 3.68:1 on the deeper one:
    /// right for a symbol or a rule, under the line for a label, and it was
    /// drawn as both in about ninety places. Ink cannot report it, because this
    /// type draws perfectly well and is simply too pale, so the only thing that
    /// can is the call site saying what it is drawing. Once every foreground
    /// goes through `pageAccentText` or `iconAccent`, the pair walk above holds
    /// each of them to its own level.
    ///
    /// Tints as well as foregrounds (#591). This read only lines containing
    /// "foreground", so twenty five sites setting a spinner, a slider or a date
    /// picker's colour with `.tint(Color.roseGold)` were outside it, and so was
    /// the app-wide tint every system control inherits. Measured, the accent is
    /// right in that role, so nothing was wrong on screen: what was wrong is
    /// that if the accent moved the way #580 moved it for type, nothing would
    /// have reported these. A rule that covers one of two spellings reads
    /// exactly like a rule that holds (#586).
    ///
    /// Matched case-insensitively so `listRowSeparatorTint` and friends are the
    /// same rule rather than a way round it.
    func testTheAccentIsNeverDrawnUnnamed() throws {
        let sources = sourcesDir
        let files = try everySourceFile()

        // Finding nothing to look at is not a pass (L98). If this walk ever
        // stops seeing the view tree it would report every screen as clean.
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep found \(files.count) source files, so it is "
                             + "proving nothing about the ones it did not read")

        for relative in files {
            let code = SwiftSourceText.withoutComments(
                try String(contentsOf: sources.appendingPathComponent(relative),
                           encoding: .utf8))
            for line in unnamedAccentUses(in: code) {
                XCTFail("""
                    \(relative) draws the raw accent, which does not say whether it is \
                    type or a symbol. As type it is 4.31:1 on the page, under the level \
                    it needs, and nothing else can tell. Use \
                    PaintedSurfaces.pageAccentText or PaintedSurfaces.iconAccent.

                    \(line)
                    """)
            }
        }
    }

    /// Lines drawing the raw accent in a role that has a name for it.
    ///
    /// Both of the ways a colour reaches a control: as a foreground, and as the
    /// tint a spinner, a slider or a picker draws itself in. "tint(" is matched
    /// on the lowercased line so `listRowSeparatorTint` and any other spelling
    /// ending in it are the same rule.
    ///
    /// Read over whole statements rather than lines (#611). A colour chosen by
    /// a ternary wraps, and the half naming the colours is then a line with no
    /// `foregroundStyle` on it at all: three of those were drawing the accent as
    /// a button's label while this reported the tree clean, which is the shape
    /// of every guard in this file that has gone blind on a spelling.
    private func unnamedAccentUses(in code: String) -> [String] {
        statements(in: code)
            .filter { $0.contains("foreground") || $0.lowercased().contains("tint(") }
            .filter { $0.contains("Color.roseGold") }
    }

    /// Source rejoined into statements, so a modifier and the colours a wrapped
    /// ternary chooses are one string to match against.
    ///
    /// A window of lines cannot do this, and the first version of the widened
    /// accent rule was one: it read two lines, the real ternary in
    /// `PhotoAssignmentView` spans three, and the guard went green on the
    /// mutation written for it while passing the two-line case it had been
    /// shaped around (L144). Joined by bracket depth instead, which is a
    /// property of the code rather than a number measured off whichever
    /// spelling happened to exist that day.
    ///
    /// String literals are blanked before the brackets are counted, so a `(` in
    /// a sentence cannot swallow the rest of the file into one statement and
    /// leave this reporting matches nobody wrote. Comments are already gone:
    /// `appSource` strips them.
    private func statements(in code: String) -> [String] {
        var out: [String] = []
        var buffer = ""
        var depth = 0

        for raw in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            buffer = buffer.isEmpty ? line : buffer + " " + line
            depth += bracketBalance(of: line)
            if depth <= 0 {
                if !buffer.isEmpty { out.append(buffer) }
                buffer = ""
                depth = 0
            }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }

    /// Open braces minus closed ones, counting neither inside a string (#630).
    ///
    /// Why this exists rather than the one statement lookahead it replaced: a
    /// colour returning helper is only ONE statement when its body is one
    /// expression. Give it an `if` or a `switch` and its colours sit in the
    /// statements after that, where the lookahead could not see them, so the
    /// exact defect the lookahead was added for came back the moment the
    /// helper grew a branch.
    private func braceBalance(of line: String) -> Int {
        guard !line.contains("\"\"\"") else { return 0 }
        let bare = line.replacingOccurrences(of: #""(\\.|[^"\\])*""#,
                                             with: "\"\"",
                                             options: .regularExpression)
        return bare.filter { $0 == "{" }.count - bare.filter { $0 == "}" }.count
    }

    /// Open brackets minus closed ones, counting neither inside a string.
    private func bracketBalance(of line: String) -> Int {
        // A multi-line literal's delimiter line carries no structure of its own.
        guard !line.contains("\"\"\"") else { return 0 }
        let bare = line.replacingOccurrences(of: #""(\\.|[^"\\])*""#,
                                             with: "\"\"",
                                             options: .regularExpression)
        return bare.filter { $0 == "(" }.count - bare.filter { $0 == ")" }.count
    }

    // MARK: - Every colour drawn as type, not just the two that were caught (#620)

    /// A palette colour written straight into a foreground or a tint.
    ///
    /// The rule the accent (#580) and the faint tone (#611) each got one at a
    /// time, generalised: a colour used as TYPE has to name the role it is
    /// playing, because only a role can be registered against what is behind it
    /// and only then can anything measure the pair.
    ///
    /// Both of those were found the same way, by somebody measuring rather than
    /// by any check, and both had been under the floor for months while the
    /// suite was green. Nothing said the class existed, so the third one was
    /// only ever going to be found the same way (L30).
    ///
    /// Reuses `statements`, so a colour reached through a ternary spread over
    /// three lines is one string to match against, which is the spelling that
    /// defeated the first version of the accent rule (L144).
    ///
    /// `Color.clear` is excluded because it draws nothing: it is a spacer and a
    /// hit area, and there is no type to read. Named here so the exemption is
    /// one decision written down once (L129).
    private func rawTypeColourUses(in code: String) -> [String] {
        let all = statements(in: code)

        // Which statements can put a colour on type. The two modifiers, plus
        // `return`, plus the body of anything declared `-> Color`, because a
        // colour handed to a foreground by a helper is type just as much as one
        // written into the modifier.
        //
        // Each of those three was added because the sweep was found blind to
        // it. `ProgramUploadView.colour(isHere:done:blocked:)` and
        // `OCRReviewView.confidenceColor` sat outside the modifiers and between
        // them held the raw accent, two of the platform's own state colours and
        // a tone at 1.60:1. Then the mutation written for this very guard put a
        // raw colour back into the FIRST of those and it stayed green, because
        // that helper is one expression with no `return` in it at all: the
        // statement after a `-> Color` declaration is its body (L1).
        var typeBearing: [String] = []
        var depth = 0
        var colourBodyDepth: Int?

        for statement in all {
            if statement.contains("foreground")
                || statement.lowercased().contains("tint(")
                || statement.contains("return ")
                || colourBodyDepth != nil {
                typeBearing.append(statement)
            }

            let before = depth
            depth += braceBalance(of: statement)

            if colourBodyDepth == nil,
               statement.range(of: #"(->|:)\s*Color\s*\{"#,
                               options: .regularExpression) != nil,
               depth > before {
                colourBodyDepth = before
            } else if let body = colourBodyDepth, depth <= body {
                colourBodyDepth = nil
            }
        }

        return typeBearing.filter { statement in
            statement.ranges(of: #/Color\.[A-Za-z][A-Za-z0-9]*/#)
                .map { String(statement[$0]) }
                .contains { $0 != "Color.clear" }
        }
    }

    /// The files that DECLARE colours rather than draw with them, and why.
    ///
    /// Written down rather than left as a silent hole in the sweep, and checked
    /// in both directions below: an entry naming a file with nothing to exempt
    /// fails too, because a stale exemption quietly covers whatever drifts into
    /// its place (L129, L96).
    private static let declaresItsOwnColours: [String: String] = [
        "Views/BrandBanner.swift":
            "declares the banner palette itself, and PaintedSurfaces.all reads "
            + "its background, icon, text and action colours straight out of it "
            + "to build the banner pairs. It is a naming site like "
            + "PaintedSurfaces, so a rule against naming colours here would be a "
            + "rule against the thing that makes the banners measurable",
        "Services/CollageRenderer.swift":
            "draws a photographic collage rather than app chrome. Its colours "
            + "are print matting inside an exported image, held by the design "
            + "version fingerprint guards rather than by contrast against a "
            + "screen nobody reads them on",
    ]

    /// No screen draws type in a colour nothing can measure (#620).
    ///
    /// `PaintedSurfaces` holds every painted FILL against the words on it, and
    /// had no rule at all about the words themselves. So `warmDark`, `warmMid`
    /// and `roseDeep` were written straight into foregrounds in hundreds of
    /// places, and whether any of them cleared its level was decided by whoever
    /// typed it.
    ///
    /// Measured, that was not academic: `warmMid` is 4.33:1 on the deeper page
    /// against the 4.5:1 body text needs (#619), the same tone at the reduced
    /// opacities dotted through these files runs from 3.74:1 down to 1.49:1,
    /// and two field placeholders were drawn at that bottom figure.
    func testNoScreenDrawsTypeInARawPaletteColour() throws {
        let files = try everySourceFile()
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep read \(files.count) source files, so it is proving "
                             + "nothing about the ones it did not open")

        var offenders: [String] = []
        for relative in files where Self.declaresItsOwnColours[relative] == nil {
            for statement in rawTypeColourUses(in: try appSource("Sources/\(relative)")) {
                offenders.append("\(relative)  \(statement.prefix(120))")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) places draw type in a colour written at the point of use. \
            Nothing can hold any of them to a level, because nothing else can name what \
            is behind them:

            \(offenders.prefix(40).joined(separator: "\n"))

            Give the role a name in PaintedSurfaces and register it in `all` against the \
            surface it is drawn on, the way the accent and the faint tone already are.
            """)
    }

    /// The matcher is asked directly what it can see (#620, L1).
    ///
    /// The tree is clean once this lands, so a matcher reading one spelling and
    /// one reading all of them give the same silent pass. Both of the earlier
    /// rules in this file shipped narrow and looked exactly like rules that
    /// held, so what has to be seen to fail is the matcher.
    func testTheTypeColourMatcherSeesEverySpelling() {
        let mustCatch = [
            "            .foregroundStyle(Color.warmMid)",
            "            .foregroundStyle(Color.warmMid.opacity(0.55))",
            "                .foregroundColor(Color.warmDark)",
            "            .tint(Color.roseDeep)",
            "            .listRowSeparatorTint(Color.creamEdge)",
            "        .foregroundStyle(Color.cream, Color.warmDark.opacity(0.7))",
            // The two colour returning helpers, which sat outside every rule in
            // this file until the sweep was widened past the modifiers.
            "        case \"high\":   return Color.green.opacity(0.8)",
            "        if blocked { return Color.warmMid.opacity(0.35) }",
        ]
        // The same helper with a branch in it (#630). The one statement
        // lookahead this replaced saw the `if` and nothing after it, so every
        // colour in a helper of more than one line was exempt.
        XCTAssertEqual(rawTypeColourUses(in: """
            private var confidenceColor: Color {
                switch suggestion.confidence {
                case "high":   PaintedSurfaces.stateSuccessText
                case "medium": PaintedSurfaces.stateWarningText
                default:       Color.warmMid.opacity(0.6)
                }
            }
            """).count, 1, """
            the check cannot see a colour inside a `-> Color` helper that BRANCHES, so a \
            screen fed its type by one of those is exempt from the rule while the one \
            line version of the same helper is caught
            """)

        // A helper that is ONE expression, so its body carries no `return` at
        // all. This is what the mutation for this guard put back, and the first
        // version of the sweep stayed green on it.
        XCTAssertEqual(rawTypeColourUses(in: """
            private func colour(isHere: Bool) -> Color {
                isHere ? Color.roseGold : Color.warmMid.opacity(0.35)
            }
            """).count, 1, """
            the check cannot see a colour returned implicitly from a `-> Color` helper, so \
            a screen fed its type by one of those is exempt from the rule
            """)
        for line in mustCatch {
            XCTAssertEqual(rawTypeColourUses(in: line).count, 1, """
                the check cannot see \(line.trimmingCharacters(in: .whitespaces)) as type \
                drawn in a colour written at the point of use, so type spelled that way is \
                exempt from the rule and reads exactly like a screen that has none
                """)
        }

        // The wrapped ternary, which is the spelling that defeated the first
        // version of the accent rule and which the line based conversion for
        // this issue could not see either (L144).
        XCTAssertEqual(rawTypeColourUses(in: """
            .foregroundStyle(stats.freshness(asOf: Date()).isStale
                             ? Color.roseDeep : Color.warmMid)
            """).count, 1, """
            the check cannot see a colour chosen by a ternary spread over two lines, so \
            type drawn that way is exempt while reading as covered
            """)

        let mustAllow = [
            "            .foregroundStyle(PaintedSurfaces.secondaryText)",
            "            .foregroundStyle(PaintedSurfaces.bodyText)",
            "        .foregroundStyle(isOn ? PaintedSurfaces.iconAccent : PaintedSurfaces.quietMark)",
            // A fill is the other rule's business, and Color.clear draws nothing.
            "            .background(Color.creamDeep)",
            "            .foregroundStyle(Color.clear)",
            "    static let warmMid   = Color(red: 122/255, green: 104/255, blue:  96/255)",
        ]
        for line in mustAllow {
            XCTAssertEqual(rawTypeColourUses(in: line).count, 0, """
                the check reports \(line.trimmingCharacters(in: .whitespaces)) as type in a \
                raw palette colour, which it is not. A rule that fires on correct code is \
                the rule people learn to work around
                """)
        }
    }

    // MARK: - The quiet tone only ever dresses a mark (#629)

    /// Uses of `quietMark` whose owning view is words, with the line number.
    ///
    /// The owner is found by walking BACK to the nearest view constructor,
    /// not by looking in a window around the line. A window is answered by
    /// whatever else happens to be nearby: both checkbox rows in photo
    /// assignment put a `Text` directly under the `Image` this colour dresses,
    /// so a window check would report the icon as words (L135).
    private func quietMarksOnWords(in code: String) -> [(Int, String)] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let marks = ["Image", "Divider", "Circle", "Capsule", "Rectangle",
                     "RoundedRectangle", "Label", "ProgressView"]

        return lines.enumerated().compactMap { index, line in
            guard line.contains("PaintedSurfaces.quietMark") else { return nil }

            for back in stride(from: index, through: Swift.max(0, index - 12), by: -1) {
                let candidate = lines[back]
                if marks.contains(where: { candidate.hasPrefix("\($0)(")
                                        || candidate.hasPrefix("\($0).") }) {
                    return nil
                }
                guard candidate.hasPrefix("Text(") else { continue }
                // Words are allowed to wear it only when nobody reads them:
                // the separator dot between two buttons is a mark that happens
                // to be typed as a character.
                let chain = lines[back...Swift.min(lines.count - 1, back + 5)]
                return chain.contains(where: { $0.contains("accessibilityHidden(true)") })
                    ? nil : (index + 1, line)
            }
            return (index + 1, line)
        }
    }

    /// Uses whose owner the walk cannot reach, with where it IS drawn.
    ///
    /// A colour returning helper has no view above it, so the walk finds
    /// nothing and reports it. Written down rather than passed over, because a
    /// use the check cannot judge and a use it approves are otherwise the same
    /// thing, and checked in both directions below so an entry that stops
    /// matching cannot quietly cover whatever replaces it (L129, L96).
    private static let quietMarkDrawnElsewhere: [String: String] = [
        "Views/OCRReviewView.swift":
            "confidenceColor fills a 6pt Circle beside a suggestion, which is a "
            + "mark and is held to the 3:1 a mark needs. The helper has no view "
            + "above it for the walk to find",
    ]

    /// `quietMark` keeps the tone that is too pale for words, so it may only
    /// ever dress a mark (#629).
    ///
    /// #620 split the palette's ink into roles and kept this one at `warmMid`,
    /// which is 4.33:1 on the deeper page: over the 3:1 a mark needs and under
    /// the 4.5:1 a sentence needs. Its documentation says it is not for words
    /// and nothing enforced that, so a sentence wearing it would be type at
    /// 4.33:1 under a name that was measured for something else, and the pair
    /// walk cannot tell: it only ever sees the colour and the level the
    /// registry claims for it.
    ///
    /// The same shape as `testEveryFaintLabelDressesAControlThatIsSwitchedOff`
    /// one role away, and for the same reason: an exemption with no reviewer is
    /// the same as no rule (L129).
    func testTheQuietToneOnlyEverDressesAMark() throws {
        let files = try everySourceFile()
        var found = 0
        var offenders: [String] = []

        for relative in files {
            let code = try appSource("Sources/\(relative)")
            found += code.components(separatedBy: "PaintedSurfaces.quietMark").count - 1
            let unjudged = quietMarksOnWords(in: code)
            if Self.quietMarkDrawnElsewhere[relative] == nil {
                for (number, line) in unjudged {
                    offenders.append("\(relative):\(number)  \(line.prefix(110))")
                }
            } else {
                XCTAssertFalse(unjudged.isEmpty, """
                    \(relative) is exempt from the quiet mark rule, because \
                    \(Self.quietMarkDrawnElsewhere[relative] ?? ""), but the check now \
                    judges every use in it. An exemption with nothing under it silently \
                    covers whatever arrives in that file next.
                    """)
            }
        }

        // A sweep that finds nothing to look at proves nothing (L98). If the
        // role were renamed this would report a clean tree over a rule that had
        // stopped covering anything.
        XCTAssertGreaterThan(found, 0,
                             "no use of PaintedSurfaces.quietMark was found at all, so this "
                             + "check is proving nothing about the role it exists for")

        XCTAssertTrue(offenders.isEmpty, """
            These draw WORDS in the quiet mark tone, which is 4.33:1 on the deeper page \
            against the 4.5:1 a sentence needs:

            \(offenders.joined(separator: "\n"))

            Use PaintedSurfaces.secondaryText for anything that is read. This tone is \
            registered as an interface element only, so a sentence wearing it is type \
            held to a level nobody measured it for.
            """)
    }

    /// The owner walk is asked what it can see (L1).
    func testTheQuietMarkOwnerWalkFindsWhatDressesIt() {
        let onAnIcon = """
            Image(systemName: allSelected ? "checkmark.square.fill" : "square")
            .font(.system(size: 12))
            .foregroundStyle(allSelected ? PaintedSurfaces.iconAccent : PaintedSurfaces.quietMark)
            Text(allSelected ? "Deselect all" : "Select all")
            .foregroundStyle(PaintedSurfaces.secondaryText)
            """
        XCTAssertEqual(quietMarksOnWords(in: onAnIcon).count, 0, """
            the check reports a checkbox mark as words, because a label sits under it in \
            the same stack. A rule that fires on correct code is the rule people learn to \
            work around
            """)

        let hiddenDot = """
            Text("·").foregroundStyle(PaintedSurfaces.quietMark)
            .accessibilityHidden(true)
            """
        XCTAssertEqual(quietMarksOnWords(in: hiddenDot).count, 0,
                       "the check reports a decorative separator nobody reads as words")

        let onASentence = """
            Text(summary)
            .font(.system(size: 11))
            .foregroundStyle(PaintedSurfaces.quietMark)
            """
        XCTAssertEqual(quietMarksOnWords(in: onASentence).count, 1, """
            the check cannot see a sentence drawn in the quiet mark tone, which is the \
            one thing this rule exists to catch
            """)
    }

    /// Every exemption still has something to exempt (#620, L96).
    ///
    /// An entry that has stopped matching anything is worse than no entry: it
    /// covers whatever drifts into that file next, and it reads as a decision
    /// somebody is still standing behind. So the list is checked in the
    /// direction nobody checks, from the exemption to the code.
    func testEveryColourExemptionStillHasSomethingToExempt() throws {
        for (relative, reason) in Self.declaresItsOwnColours {
            let code = try appSource("Sources/\(relative)")
            XCTAssertFalse(rawTypeColourUses(in: code).isEmpty, """
                \(relative) is exempt from the type colour rule, on the grounds that it \
                \(reason), but it no longer names a colour of its own. An exemption with \
                nothing under it silently covers whatever arrives in that file next.
                """)
        }
    }

    // MARK: - The faint tone (#611)

    /// Every use of the faint tone, whatever it is drawn as.
    ///
    /// Not "used as a foreground", which is the mistake the accent rule above
    /// had to be widened out of: the colour reaches type through a wrapped
    /// ternary as readily as through a `foregroundStyle`, and a matcher that
    /// reads one spelling is indistinguishable from one that holds. So the rule
    /// is that this token is not written outside the file that names its roles
    /// at all. `PaintedSurfaces.swift` declares the roles and is excluded from
    /// the sweep, which is where the one remaining use of it lives.
    private func rawFaintToneUses(in code: String) -> [String] {
        code.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("Color.warmFaint") }
    }

    /// The faint tone is never drawn at a call site (#611).
    ///
    /// `warmFaint` measures 2.43:1 on the page, under the 4.5:1 body text needs
    /// and under even the 3:1 an interface element needs, and it was the
    /// foreground of 14 text draws across three screens. Nothing reported it:
    /// the pair registry never held it, so the harness built to catch exactly
    /// this had never been given it (L143, the same shape as #580).
    ///
    /// It still has one honest role, the label of a control that is switched
    /// off, which WCAG exempts. That role has a name now, and
    /// `testEveryFaintLabelDressesAControlThatIsSwitchedOff` below is what holds
    /// the exemption to controls that really are inactive (L129).
    func testTheFaintToneIsNeverDrawnAtACallSite() throws {
        let files = try everySourceFile()
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep read \(files.count) source files, so it is proving "
                             + "nothing about the ones it did not open")

        for relative in files {
            for line in rawFaintToneUses(in: try appSource("Sources/\(relative)")) {
                XCTFail("""
                    \(relative) draws Color.warmFaint, which is 2.43:1 on the page and \
                    says nothing about which role it is playing. Nothing can measure it \
                    from here, because nothing else can name it. Use \
                    PaintedSurfaces.tertiaryText for type, PaintedSurfaces.fieldPlaceholder \
                    inside a field, or PaintedSurfaces.disabledControlLabel on a control \
                    that is switched off.

                    \(line)
                    """)
            }
        }
    }

    /// The faint matcher is asked what it can see (#611, L1).
    ///
    /// The tree is clean once this issue lands, and a clean tree cannot tell a
    /// matcher that reads every spelling from one that reads the first it was
    /// written for. Both give the same silent pass.
    func testTheFaintToneMatcherSeesEverySpelling() {
        let mustCatch = [
            "            .foregroundStyle(Color.warmFaint)",
            "                             ? Color.warmFaint : Color.roseGold)",
            "                .foregroundStyle(Color.warmFaint.opacity(0.45))",
            "            .foregroundStyle(draftIsChange ? PaintedSurfaces.pageAccentText : Color.warmFaint)",
        ]
        for line in mustCatch {
            XCTAssertEqual(rawFaintToneUses(in: line).count, 1, """
                the check cannot see \(line.trimmingCharacters(in: .whitespaces)) as a raw \
                use of the faint tone, so type drawn that way is exempt from the rule and \
                reads exactly like a screen that has none
                """)
        }

        let mustAllow = [
            "            .foregroundStyle(PaintedSurfaces.tertiaryText)",
            "            .foregroundStyle(PaintedSurfaces.disabledControlLabel)",
            "                .foregroundStyle(Color.warmMid)",
        ]
        for line in mustAllow {
            XCTAssertEqual(rawFaintToneUses(in: line).count, 0, """
                the check reports \(line.trimmingCharacters(in: .whitespaces)) as a raw use \
                of the faint tone, which it is not. A rule that fires on correct code is \
                the rule people learn to work around
                """)
        }
    }

    /// Uses of the disabled-label colour with no switched-off control near them.
    ///
    /// The window reaches two lines back and six forward, which is what the
    /// wrapped ternary spellings in this app actually span: the colour is chosen
    /// inside the label and `.disabled(` lands after the button's style.
    private func faintLabelsOnLiveControls(in code: String) -> [(Int, String)] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.enumerated().compactMap { index, line in
            guard line.contains("PaintedSurfaces.disabledControlLabel") else { return nil }
            let window = lines[Swift.max(0, index - 2)...Swift.min(lines.count - 1, index + 6)]
            return window.contains { $0.contains(".disabled(") } ? nil : (index + 1, line)
        }
    }

    /// The one colour under the floor only ever dresses an inactive control
    /// (#611).
    ///
    /// WCAG 1.4.3 exempts the text of an inactive component from its contrast
    /// minimum, which is why the four greyed-out labels in this app keep a tone
    /// nothing else may use. An exemption with no reviewer is the same as no
    /// rule (L129), so this is the reviewer: the exempt colour has to be on a
    /// control that is switched off, or it is ordinary type wearing 2.43:1.
    func testEveryFaintLabelDressesAControlThatIsSwitchedOff() throws {
        let files = try everySourceFile()
        var found = 0

        for relative in files {
            let code = try appSource("Sources/\(relative)")
            found += code.components(separatedBy: "PaintedSurfaces.disabledControlLabel").count - 1
            for (number, line) in faintLabelsOnLiveControls(in: code) {
                XCTFail("""
                    \(relative):\(number) draws the disabled-label colour on a control with \
                    no .disabled( near it. That tone is 2.43:1 and is exempt only because \
                    an inactive component is exempt; on a live control it is unreadable \
                    type that no check will ever object to.

                    \(line)
                    """)
            }
        }

        // A sweep that finds no subjects is not a sweep that passed (L98). The
        // four sites are the reason the exemption exists; if they leave, the
        // exemption should leave with them rather than sitting here unused.
        XCTAssertGreaterThan(found, 0, """
            nothing in the app draws PaintedSurfaces.disabledControlLabel any more, so the \
            one colour allowed under the contrast floor has no user and should be deleted \
            rather than left as a way around the rule.
            """)
    }

    /// The disabled-label matcher is asked what it can see (#611, L1).
    func testTheDisabledLabelMatcherSeesALiveControl() {
        let live = """
            Button("Send to Claude") { }
                .buttonStyle(.plain)
                .foregroundStyle(PaintedSurfaces.disabledControlLabel)
            """
        XCTAssertEqual(faintLabelsOnLiveControls(in: live).count, 1, """
            the check cannot see the exempt colour drawn on a control that is not \
            disabled, which is the only thing it exists to catch
            """)

        let inactive = """
            Button("Send to Claude") { }
                .foregroundStyle(empty ? PaintedSurfaces.disabledControlLabel
                                 : PaintedSurfaces.pageAccentText)
                .buttonStyle(.plain)
                .disabled(empty)
            """
        XCTAssertEqual(faintLabelsOnLiveControls(in: inactive).count, 0, """
            the check reports a genuinely switched-off control as an offender, which is \
            the state the exemption is for
            """)
    }

    /// The matcher is asked directly what it can see (#591, L1).
    ///
    /// Running it over the real tree cannot answer this once the tree is clean:
    /// a matcher that reads foregrounds only and one that reads tints as well
    /// give the same silent pass, and the narrow one shipped for two issues
    /// looking correct. What has to be seen to fail is the matcher, not the
    /// codebase around it (#586).
    func testTheAccentMatcherSeesEveryRoleTheAccentIsDrawnIn() {
        let mustCatch = [
            "            .foregroundStyle(Color.roseGold)",
            "                .tint(Color.roseGold)",
            "                ProgressView().controlSize(.small).tint(Color.roseGold)",
            "            .listRowSeparatorTint(Color.roseGold)",
        ]
        // The wrapped ternary, invisible here until #611: the half naming the
        // colours carries no modifier at all. Both widths, because the first
        // version of the fix read two lines, the real one in
        // PhotoAssignmentView spans three, and it went green on exactly the
        // mutation written for it (L144).
        let wrapped = [
            """
            .foregroundStyle(canGoPrevious
                             ? Color.roseGold : PaintedSurfaces.disabledControlLabel)
            """,
            """
            .foregroundStyle(tagsBinding.wrappedValue.isEmpty
                             ? PaintedSurfaces.disabledControlLabel
                             : Color.roseGold)
            """,
        ]
        for spelling in wrapped {
            XCTAssertEqual(unnamedAccentUses(in: spelling).count, 1, """
                the check cannot see the accent chosen by a ternary spread over \
                \(spelling.split(separator: "\n").count) lines, so a label drawn that way \
                is exempt from the rule while reading as covered by it
                """)
        }

        // A bracket inside a sentence is not structure. Left uncounted, the
        // statement below never closes and everything after it joins on, which
        // would have this reporting matches in code nobody wrote.
        XCTAssertEqual(unnamedAccentUses(in: """
            .help("Copies this photo's tags onto every photo :-( in this day")
            .foregroundStyle(PaintedSurfaces.pageAccentText)
            Capsule().fill(Color.roseGold.opacity(0.15))
            """).count, 0, """
            the check joins a statement past an unbalanced bracket inside a string, so it \
            reads a fill three lines away as part of a foreground and fails on correct code
            """)
        for line in mustCatch {
            XCTAssertEqual(unnamedAccentUses(in: line).count, 1, """
                the check cannot see \(line.trimmingCharacters(in: .whitespaces)) as the \
                raw accent, so a control coloured that way is exempt from the rule and \
                reads exactly like a screen that has none
                """)
        }

        let mustAllow = [
            "                .tint(PaintedSurfaces.iconAccent)",
            "                .tint(PaintedSurfaces.photoPlaceholderSpinner)",
            "            .foregroundStyle(PaintedSurfaces.pageAccentText)",
            "                .tint(Color.warmMid)",
            "    static let iconAccent = Color.roseGold",
        ]
        for line in mustAllow {
            XCTAssertEqual(unnamedAccentUses(in: line).count, 0, """
                the check reports \(line.trimmingCharacters(in: .whitespaces)) as the raw \
                accent, which it is not. A rule that fires on correct code is the rule \
                people learn to work around
                """)
        }
    }

    /// Lines drawing a system colour as type or as a control's tint.
    ///
    /// The platform's palette is the one this app's rules could never reach.
    /// `PaintedSurfaces` names what this app paints, and a system colour is
    /// named by neither side: not by the palette, and not by anything that
    /// could say which surface it lands on. Three issues in a row turned out to
    /// be exactly that, and all three were genuinely under the level once
    /// somebody measured them: the event row's detail lines at 3.68:1 (#590),
    /// the Settings footers at 3.95:1 (#596), and the state labels at 2.22:1,
    /// 2.31:1 and 3.57:1 (#598).
    ///
    /// Matched on the bare leading dot, which is the spelling that means "the
    /// system's", so `PaintedSurfaces.photoScrimText` and `Color.warmDark` pass
    /// and `.white` does not.
    private func systemColourForegrounds(in code: String) -> [String] {
        let pattern = #"(foregroundStyle|foregroundColor|tint)\(\s*\."# +
            #"(white|black|red|orange|yellow|green|blue|purple|pink|brown|"# +
            #"gray|grey|mint|teal|cyan|indigo|secondary|primary|accentColor)\b"#
        return code.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    /// No screen draws type in a system colour (#598).
    ///
    /// One rule over the whole tree rather than a scoped copy per screen. #590
    /// and #596 each banned these inside one declaration, which leaves the next
    /// screen exempt by default and makes the guard's reach a list of the
    /// places somebody had already thought about (L96).
    func testNoScreenDrawsTypeInASystemColour() throws {
        let sources = sourcesDir
        let files = try everySourceFile()

        // Finding nothing to look at is not a pass (L98).
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep found \(files.count) source files, so it is "
                             + "proving nothing about the ones it did not read")

        for relative in files {
            let code = SwiftSourceText.withoutComments(
                try String(contentsOf: sources.appendingPathComponent(relative),
                           encoding: .utf8))
            for line in systemColourForegrounds(in: code) {
                XCTFail("""
                    \(relative) draws type in one of the platform's own colours. Nothing \
                    can measure it: it is not in this app's palette, so no pair names \
                    it, and the surface it lands on is not named either. Add the pair to \
                    PaintedSurfaces and draw from there.

                    \(line)
                    """)
            }
        }
    }

    /// The matcher is asked directly what it can see (#598, L1).
    ///
    /// Once the tree is clean, a matcher that reads `.white` and one that reads
    /// nothing give the same silent pass, so what has to be seen to fail is the
    /// matcher rather than the codebase around it (#586).
    func testTheSystemColourMatcherSeesEverySpelling() {
        let mustCatch = [
            ".foregroundStyle(.white)",
            ".foregroundStyle(.white.opacity(0.85))",
            ".foregroundStyle(.secondary)",
            ".foregroundColor(.red)",
            "ProgressView().controlSize(.small).tint(.white)",
            ".foregroundStyle(.orange)",
            ".foregroundStyle( .green )",
            ".foregroundStyle(.white.opacity(0.9), Color.warmDark.opacity(0.5))",
        ]
        for line in mustCatch {
            XCTAssertEqual(systemColourForegrounds(in: line).count, 1, """
                the check cannot see \(line) as a system colour, so type drawn that way \
                is exempt from the rule and reads exactly like a screen with none
                """)
        }

        let mustAllow = [
            ".foregroundStyle(PaintedSurfaces.photoScrimText)",
            ".foregroundStyle(Color.warmDark)",
            ".tint(PaintedSurfaces.iconAccent)",
            ".background(Color.black.opacity(0.65))",
            ".shadow(color: .black.opacity(0.5), radius: 24, y: 6)",
            ".symbolRenderingMode(.palette)",
            "ProgressView().progressViewStyle(.circular)",
            ".foregroundStyle(PaintedSurfaces.stateWarningText)",
        ]
        for line in mustAllow {
            XCTAssertEqual(systemColourForegrounds(in: line).count, 0, """
                the check reports \(line) as a system colour, which it is not. A rule \
                that fires on correct code is the rule people learn to work around
                """)
        }
    }

    /// Every colour this file names can be resolved back from its name (#580).
    ///
    /// The checks that read source recognise `Color.<token>`. Naming a colour
    /// moves it out of their reach, and a name they cannot resolve reads as
    /// nothing being set, which no rule can object to: the guard goes quiet
    /// rather than red. `byName` is what turns a name back into its colour, so
    /// a declaration missing from it silently exempts whatever it is put on
    /// (L96).
    func testEveryNamedColourIsResolvable() throws {
        let code = try appSource("Sources/Views/PaintedSurfaces.swift")
        let declared = code
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let r = line.range(of: #"static let (\w+) = "#,
                                         options: .regularExpression) else { return nil }
                return String(line[r])
                    .replacingOccurrences(of: "static let ", with: "")
                    .replacingOccurrences(of: " = ", with: "")
            }
            // byName itself is the table, not an entry in it.
            .filter { $0 != "byName" }

        XCTAssertGreaterThan(declared.count, 10,
                             "the scan read \(declared.count) declarations, so it is not "
                             + "looking at the file it is about")
        for name in declared {
            XCTAssertNotNil(PaintedSurfaces.byName[name], """
                PaintedSurfaces.\(name) cannot be resolved from its name, so any check \
                that reads source sees a call site using it as having no colour set, \
                and stays green whatever it is drawn in.
                """)
        }
    }

    private var viewsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent("Sources/Views")
    }

    private var sourcesDir: URL {
        viewsDir.deletingLastPathComponent()
    }

    /// Every source file, at any depth, minus the one that holds the names.
    ///
    /// Rooted at `Sources` rather than `Sources/Views` (#586). Which folder a
    /// painted surface is declared in says nothing about whether it is painted:
    /// the app's one remaining raw fill was a rule in `DesignTokens.swift`,
    /// exempt purely because of where it lived, and nothing stopped the next
    /// panel being written there too.
    ///
    /// One walk shared by both sweeps rather than a copy each, so widening the
    /// tree cannot reach one of them and leave the other reading a subset
    /// nobody notices (L16).
    private func everySourceFile() throws -> [String] {
        try FileManager.default
            .subpathsOfDirectory(atPath: sourcesDir.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { !$0.hasSuffix("PaintedSurfaces.swift") }
            .sorted()
    }

    private func appSource(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent(relative)
        return SwiftSourceText.withoutComments(
            try String(contentsOf: url, encoding: .utf8))
    }

    /// WCAG relative luminance, on the two colours as they will actually be
    /// drawn, so a token change moves this rather than leaving it asserting a
    /// pair of numbers that no longer ship.
    private func contrastRatio(_ a: Color, _ b: Color) -> Double {
        func luminance(_ colour: Color) -> Double {
            let rgb = NSColor(colour).usingColorSpace(.sRGB) ?? .white
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.redComponent)
                 + 0.7152 * channel(rgb.greenComponent)
                 + 0.0722 * channel(rgb.blueComponent)
        }
        let one = luminance(a), two = luminance(b)
        return (Swift.max(one, two) + 0.05) / (Swift.min(one, two) + 0.05)
    }

    /// The same question for the staleness notice, whose type sits on its own
    /// panel rather than on the page (#559).
    func testTheStalenessNoticeHasReadableContrastAgainstItsPanel() throws {
        let sentence = try surface("insights staleness notice", "sentence")
        let symbol = try surface("insights staleness notice", "icon")
        let text = contrastRatio(sentence.foreground, sentence.background)
        let icon = contrastRatio(symbol.foreground, symbol.background)

        XCTAssertGreaterThan(text, sentence.kind.floor,
                             "the notice's sentence is at \(String(format: "%.2f", text)):1 "
                             + "against the panel it sits on")
        XCTAssertGreaterThan(icon, symbol.kind.floor,
                             "the notice's icon is at \(String(format: "%.2f", icon)):1 "
                             + "against the panel it sits on")
    }

    /// One of the two checks left in the suite that are about INK (#614).
    ///
    /// The threshold it uses is no longer what any surface is judged by, and
    /// that is the point of keeping it: this records that a control with no
    /// words at all still measures as a respectable amount of ink, which is why
    /// ink was the wrong quantity to ask any of these surfaces about.
    func testTheUnrenderableControlsAreNamedRatherThanMeasured() throws {
        let spinnerOnly = WordFootprint.ink(try render(ProgressView().frame(height: 40)))
        XCTAssertGreaterThan(spinnerOnly, Self.legibleInk, """
            A bare ProgressView measured \(String(format: "%.4f", spinnerOnly)), which \
            clears the legibility threshold while drawing no words at all. If this \
            ever stops being true, ImageRenderer has learned to draw it and the \
            states above can carry their menus again.
            """)

        let words = WordFootprint.share(try render(ProgressView().frame(height: 40)),
                                        try render(ProgressView().frame(height: 40),
                                                   wordless: true))
        XCTAssertLessThan(words, WordFootprint.drawn, """
            A bare ProgressView has a word footprint of \(String(format: "%.4f", words)), \
            so the measurement every surface is now judged by is reading something as \
            type on a control that has none.
            """)
    }

    /// The measurement has to be able to tell legible from invisible, or the
    /// checks above are decoration that would pass on an empty page.
    ///
    /// One view, rendered twice, differing only in the colour of the type. That
    /// is the defect in its bare form and exactly how it has shipped here three
    /// times: text drawn in the colour of the surface behind it.
    ///
    /// Deliberately NOT a BrandBanner, because a banner also paints a fill and a
    /// border, and those put ink on the page whatever the text does. What is
    /// being proven is that the metric can distinguish.
    func testTheMeasurementTellsLegibleTypeFromInvisibleType() throws {
        func card(_ colour: Color) -> some View {
            ZStack {
                Color.cream
                Text("You may or may not be able to read this sentence.")
                    .font(.system(size: 12))
                    .foregroundStyle(colour)
            }
            .frame(height: 60)
        }

        func share(_ colour: Color) throws -> Double {
            WordFootprint.share(try render(card(colour)),
                                try render(card(colour), wordless: true))
        }
        let invisible = try share(.cream)
        let legible = try share(.warmDark)

        XCTAssertLessThan(invisible, WordFootprint.drawn,
                          "type drawn in its own background colour has to measure as "
                          + "nothing, or the floor is above the defect it exists to catch")
        XCTAssertGreaterThan(legible, WordFootprint.drawn * 5,
                             "the same words in a readable colour have to be worth far more "
                             + "than the floor, or the metric is not reading the type at all")
    }

    /// The measurement's own zero, measured rather than assumed (L1, #614).
    ///
    /// The floor every surface in the suite is judged by is a margin over "no
    /// difference at all". If two renders of one view ever stopped agreeing,
    /// every figure in these checks would be noise and the floor would be
    /// measuring the renderer instead of the type.
    ///
    /// Taken on a real surface from this file rather than a shape invented for
    /// it, because what has to be stable is the rendering of the things
    /// actually being measured.
    func testTheFootprintOfNothingIsNothing() throws {
        let state = try XCTUnwrap(states.first)
        XCTAssertEqual(WordFootprint.share(try render(state.view),
                                           try render(state.view)),
                       0, accuracy: 0.00001, """
            two renders of "\(state.name)" differ, so the footprint measurement is \
            reading the renderer rather than the words and the floor it is judged \
            against means nothing
            """)
    }
}

#if POSTROLL_TESTS
extension BannerLegibilityTests {
    /// Writes every banner state to PNG so a person can look at them, which is
    /// the whole point of #389 and the only reason the run-on was ever found.
    ///
    /// It asserts, rather than merely producing files: a utility in the suite
    /// that cannot fail is indistinguishable from one that silently stopped
    /// working, and this codebase already treats that as a defect.
    func testDumpBannersForReview() throws {
        // Into the one shared folder now (#623), so the notices sit beside the
        // screens they appear on rather than in a directory of their own that
        // has to be found separately. `ReviewSheet` empties it once per process
        // and prints where it is.
        for state in states {
            try ReviewSheet.write(try render(state.view),
                                  group: Self.reviewGroup, name: state.name)
        }

        let written = try ReviewSheet.written(group: Self.reviewGroup)
        ReviewSheet.announce(group: Self.reviewGroup, count: written.count)

        XCTAssertEqual(written.count, states.count, """
            \(states.count) notices were rendered and \(written.count) reached \
            \(ReviewSheet.folder.path). A review of these images is otherwise a review \
            of whichever ones happened to be written.
            """)
    }

    fileprivate static let reviewGroup = "notices"
}
#endif
