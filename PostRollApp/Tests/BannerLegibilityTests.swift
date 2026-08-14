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
    private func render(_ view: some View, width: CGFloat = 520) throws -> NSBitmapImageRep {
        // On Color.cream, because that is the surface every one of these sits
        // on in the app. A banner fill is translucent, so rendered against
        // nothing it is mostly transparent and every measurement below would be
        // taken on a page the person never sees.
        let renderer = ImageRenderer(content: ZStack {
            Color.cream
            view.padding(Spacing.md)
        }.frame(width: width))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the banner produced no image at all")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    /// The share of pixels that differ noticeably from the most common colour.
    ///
    /// The most common colour IS the background (a banner is mostly its own
    /// fill), so this measures how much of the image is something else: text,
    /// icon, border. Near zero means the message is there in the view tree and
    /// invisible on screen, which is the failure that keeps recurring.
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
        // The fill is whatever most of the page is, so the median IS the
        // background whether the banner is light or dark.
        let background = luminances.sorted()[luminances.count / 2]
        let ink = luminances.filter { abs($0 - background) > 0.12 }
        return Double(ink.count) / Double(luminances.count)
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

    func testEveryBannerActuallyDrawsItsMessage() throws {
        for state in states {
            let coverage = inkCoverage(try render(state.view))
            XCTAssertGreaterThan(coverage, Self.legibleInk, """
                The "\(state.name)" banner rendered almost nothing but its own \
                background (\(String(format: "%.3f", coverage)) of pixels differ). \
                The message exists in the view tree and cannot be read on screen.
                """)
        }
    }

    /// What each surface actually measures, so the threshold above stays a
    /// measured number rather than one carried forward on faith (#396).
    ///
    /// Printed rather than asserted per surface: pinning each figure would fail on
    /// every legitimate wording change, which is a guard asserting a rendering
    /// instead of the rule behind it (L103). What IS asserted is the property the
    /// threshold depends on, that the thinnest real surface still clears it with
    /// room, so adding a screen cannot quietly drag the band down onto blank.
    func testTheThinnestRealSurfaceStillClearsTheThresholdWithRoom() throws {
        var measured: [(String, Double)] = []
        for state in states {
            measured.append((state.name, inkCoverage(try render(state.view))))
        }
        let sorted = measured.sorted { $0.1 < $1.1 }
        for (name, coverage) in sorted {
            print(String(format: "  %.4f  %@", coverage, name))
        }

        let thinnest = try XCTUnwrap(sorted.first)
        XCTAssertGreaterThan(thinnest.1, Self.legibleInk * 1.5, """
            "\(thinnest.0)" measures \(String(format: "%.4f", thinnest.1)), which is \
            close enough to the \(Self.legibleInk) threshold that the check above can \
            no longer tell a thin surface from a blank one. Re-measure the threshold \
            against the real band rather than lowering it.
            """)
    }

    /// A banner is worth nothing if the words run past the edge of it. Rendering
    /// at a narrow width is where a long message with a two button row breaks.
    func testEveryBannerStillDrawsItsMessageWhenNarrow() throws {
        for state in states {
            let coverage = inkCoverage(try render(state.view, width: 300))
            XCTAssertGreaterThan(coverage, Self.legibleInk,
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

        let invisible = inkCoverage(try render(button(.cream)))
        let legible = inkCoverage(try render(button(.warmDark)))

        XCTAssertLessThan(invisible, 0.001, """
            A button whose label is drawn in its own background colour measured \
            \(String(format: "%.4f", invisible)), so something other than its words \
            is putting ink on the page. If ImageRenderer has started substituting a \
            placeholder for Button the way it does for Menu, the rescan offer below \
            is being measured on that block rather than on anything readable.
            """)
        XCTAssertGreaterThan(legible, invisible * 10,
                             "the same button label in a readable colour has to measure "
                             + "as far more ink, or its words are not being drawn")
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
        let files = try everyViewFile()

        // A sweep that reads nothing objects to nothing (L98). The five-file
        // version of this could not have told you it had gone blind either.
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep read \(files.count) view files, so it is proving "
                             + "nothing about the ones it did not open")

        for relative in files {
            let code = try viewSource("Sources/Views/\(relative)")
            XCTAssertFalse(code.contains(".background(Color."), """
                \(relative) paints a background from a colour written at the point of \
                use. Nothing can check the words against it, because nothing else can \
                name it. Add it to PaintedSurfaces and draw from there.
                """)
            XCTAssertFalse(code.contains(".fill(Color."), """
                \(relative) fills a shape from a colour written at the point of use. \
                Same problem: an unnamed fill is a surface no legibility check can \
                reach.
                """)
        }
    }

    /// The accent may not be drawn as a foreground without saying which role it
    /// is in (#580).
    ///
    /// `roseGold` measures 4.31:1 on the page and 3.68:1 on the deeper one:
    /// right for a symbol or a rule, under the line for a label, and it was
    /// drawn as both in about ninety places. Ink cannot report it, because this
    /// type draws perfectly well and is simply too pale, so the only thing that
    /// can is the call site saying what it is drawing. Once every foreground
    /// goes through `pageAccentText` or `iconAccent`, the pair walk above holds
    /// each of them to its own level.
    func testTheAccentIsNeverDrawnUnnamed() throws {
        let views = viewsDir
        let files = try everyViewFile()

        // Finding nothing to look at is not a pass (L98). If this walk ever
        // stops seeing the view tree it would report every screen as clean.
        XCTAssertGreaterThan(files.count, 20,
                             "the sweep found \(files.count) view files, so it is "
                             + "proving nothing about the ones it did not read")

        for relative in files {
            let code = SwiftSourceText.withoutComments(
                try String(contentsOf: views.appendingPathComponent(relative),
                           encoding: .utf8))
            for line in code.split(separator: "\n") where line.contains("foreground") {
                XCTAssertFalse(line.contains("Color.roseGold"), """
                    \(relative) draws a foreground in the raw accent, which does not \
                    say whether it is type or a symbol. As type it is 4.31:1 on the \
                    page, under the level it needs, and nothing else can tell. Use \
                    PaintedSurfaces.pageAccentText or PaintedSurfaces.iconAccent.
                    """)
            }
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
        let code = try viewSource("Sources/Views/PaintedSurfaces.swift")
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

    /// Every view file, at any depth, minus the one that holds the names.
    ///
    /// One walk shared by both sweeps rather than a copy each, so widening the
    /// tree cannot reach one of them and leave the other reading a subset
    /// nobody notices (L16).
    private func everyViewFile() throws -> [String] {
        try FileManager.default
            .subpathsOfDirectory(atPath: viewsDir.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { !$0.hasSuffix("PaintedSurfaces.swift") }
            .sorted()
    }

    private func viewSource(_ relative: String) throws -> String {
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

    func testTheUnrenderableControlsAreNamedRatherThanMeasured() throws {
        let spinnerOnly = inkCoverage(try render(ProgressView().frame(height: 40)))
        XCTAssertGreaterThan(spinnerOnly, Self.legibleInk, """
            A bare ProgressView measured \(String(format: "%.4f", spinnerOnly)), which \
            clears the legibility threshold while drawing no words at all. If this \
            ever stops being true, ImageRenderer has learned to draw it and the \
            states above can carry their menus again.
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

        let invisible = inkCoverage(try render(card(.cream)))
        let legible = inkCoverage(try render(card(.warmDark)))

        XCTAssertLessThan(invisible, 0.001,
                          "type drawn in its own background colour has to measure as blank")
        XCTAssertGreaterThan(legible, invisible * 10,
                             "the same words in a readable colour have to measure as far more "
                             + "ink, or the metric is not reading the type at all")
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
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POSTROLL_BANNER_DUMP"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("postroll-banners").path)
        // Cleared first: an image left by an earlier run is a picture of a
        // state the app may no longer produce, and reviewing it is worse than
        // reviewing nothing.
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for state in states {
            let rep = try render(state.view)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent(
                state.name.replacingOccurrences(of: " ", with: "-") + ".png"))
        }

        let written = try FileManager.default.contentsOfDirectory(atPath: out.path)
            .filter { $0.hasSuffix(".png") }
        XCTAssertEqual(written.count, states.count,
                       "every state has to reach disk, or a review of these images is a "
                       + "review of whichever ones happened to be written")
    }
}
#endif
