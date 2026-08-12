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
    /// (#391, #396). With the four stage screens in, the thirty-one real states
    /// render between 0.022 and 0.130, and a page with nothing legible on it
    /// renders at 0.001. This sits below the thinnest real one (a single line of
    /// text) and far above blank.
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
            ("ocr notices, all four", AnyView(OCRReviewNotices(
                detectedIssues: ocrIssues,
                partialProgramNotes: [ProgramShortfall.acceptanceNote(for: incomplete)],
                visionSkippedMessage: OCRReviewReadiness.visionSkippedMessage(
                    "The program pages were too large to read."),
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
