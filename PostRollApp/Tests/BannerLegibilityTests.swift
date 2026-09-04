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
    /// Static and visible to the sliced sweeps in `BannerSweepTests` (#1257),
    /// which took two of this class's tests out. One implementation and one
    /// memo, because sharing the DATA while copying the code that applies it is
    /// not consolidation (L370).
    static func render(_ view: some View, width: CGFloat = 520,
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
    static var measuredStates: [(name: String, view: AnyView)] { allStates }

    fileprivate var states: [(name: String, view: AnyView)] { Self.allStates }

    /// Built once per run, not once per access (#1018).
    ///
    /// Three tests here sweep it and `UnseenSurfaceTests` and
    /// `HostedControlLegibilityTests` take it through `measuredStates`, so a
    /// property rebuilding forty view trees on every access was rebuilding them
    /// several hundred times for an answer that cannot change: nothing below
    /// reads anything but its own app types.
    ///
    /// `static let` rather than a cache with a key, because there is only ever
    /// one answer, so there is no key to get wrong and no empty result a memo
    /// could latch onto (L286).
    private static let allStates: [(name: String, view: AnyView)] = buildStates()

    private static func buildStates() -> [(name: String, view: AnyView)] {
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
            // The longest state it has, which is the one that has to fit and
            // stay readable: a branch AND unsaved work (#664).
            ("checkout not on main", AnyView(BrandBanner(
                icon: CheckoutNotice.icon,
                message: CheckoutNotice.message(
                    for: .known(commit: "1a2b3c4", branch: "wip/pinned-text-shaper",
                                dirty: true)) ?? "",
                style: .warning))),
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
                    regeneratingDays: [.thursday, .wednesday],
                    staleDays: []) ?? "")))),
            // The rows rather than the region that holds them (#743). The stack
            // is capped and scrolls past `CaptionReviewNotices.maximumHeight`,
            // so hosting it here would measure the contrast of whichever three
            // rows happened to be at the top and report the rest as absent,
            // and a capped region stops getting taller when squeezed, which is
            // exactly the signature the truncation harness next door reads as
            // dropped words. What the cap does is measured in
            // CaptionNoticeStackTests; what these measure is every row's text.
            ("caption notices", AnyView(CaptionReviewNotices(
                failedDayCount: failedWeek.errorCount,
                regenerateError: "Regeneration failed: exit 1",
                // The refusal row, drawn alongside the week's banner rather
                // than instead of it (#731), so the row that says a click did
                // nothing is measured for contrast like every other banner and
                // is pictured WITH the notice that used to hide it.
                refusal: "Two of the five clips could not be copied, so they were left out.",
                rebuildRefusal: "Friday is already rebuilding, so nothing was changed.",
                skippedPhotoNotices: DayName.allCases.compactMap { day in
                    failedWeek.warningMessage(for: day).map {
                        CaptionReviewDayNotice(id: day.rawValue,
                                               message: "\(day.displayName): \($0)")
                    }
                },
                mediaWarnings: [CaptionReviewDayNotice(
                    id: "tuesday",
                    message: "Tuesday: the chosen black and white photo has moved")],
                // The per-slot rebuild failures (#721). Drawn here so the rows
                // that now outlive the screen are measured like every other
                // banner, including their Dismiss.
                dayRebuildFailures: [CaptionReviewDayNotice(
                    id: "thursday",
                    message: "Thursday audio swap failed: the track could not be fetched")],
                coverRebuildFailures: [CaptionReviewDayNotice(
                    id: "friday",
                    message: "Friday cover regeneration failed: the chosen frame has moved")])
                .noticeRows)),

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
                message: NewEventValidation.refusal(name: "") ?? ""))),

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
        ] + Self.notificationBanners
    }

    /// One state's word footprint at one width, measured once per run (#1018).
    ///
    /// `testEveryBannerActuallyDrawsItsMessage` and
    /// `testTheThinnestRealSurfaceStillClearsTheThresholdWithRoom` compute the
    /// IDENTICAL pair for every state: the same view, at the same 520pt, once
    /// as it ships and once with its type switched off. Two renders each, forty
    /// states, twice over, for one set of numbers. That was most of this file's
    /// 74s on the runner (audit lesson 30).
    ///
    /// Keyed by WIDTH as well as by state, which is load bearing:
    /// `testEveryBannerStillDrawsItsMessageWhenNarrow` asks the same question at
    /// 300pt, and a memo keyed on the state alone would hand it the 520pt
    /// answer for every surface. It would then measure nothing at all while
    /// passing, which is the one direction nothing else here would catch (L98).
    /// `testTheShareMemoIsKeyedByWidthAsWellAsByState` holds that open.
    ///
    /// A render that THROWS stores nothing, because the store happens after it:
    /// a cached failure would be read as a measurement by every later caller.
    private struct ShareKey: Hashable {
        let state: String
        let width: CGFloat
    }

    private static var measuredShares: [ShareKey: Double] = [:]

    static func wordShare(of state: (name: String, view: AnyView),
                          width: CGFloat = 520) throws -> Double {
        let key = ShareKey(state: state.name, width: width)
        if let already = Self.measuredShares[key] { return already }
        let share = WordFootprint.share(
            try render(state.view, width: width),
            try render(state.view, width: width, wordless: true))
        Self.measuredShares[key] = share
        return share
    }

    /// The banner saying nothing this app announces can arrive (#894, #918).
    ///
    /// Named by #918 as one of two panes nobody had ever seen. It corrects that
    /// issue's premise on one point: the banner is not in Settings, it is on
    /// the main window (`MainWindowView.swift`), drawn above the save failure
    /// because it silences everything else the app would have said. It is
    /// genuinely unrendered though, which is what the issue was about:
    /// `NotificationReachabilityTests` checks the SENTENCE each state produces
    /// and nothing has ever drawn one.
    ///
    /// One per permission that has something to say, and which those are is
    /// asked of the type rather than listed here, so a state that starts
    /// complaining is on the sheet the day it does (L96).
    static var notificationBanners: [(name: String, view: AnyView)] {
        complainingPermissions.map { named in
            ("notifications \(named.name)",
             AnyView(BrandBanner(
                icon: "bell.slash.fill",
                message: NotificationNotice.message(permission: named.permission,
                                                    hasAsked: true) ?? "",
                style: .warning)))
        }
    }

    /// Every permission a complaint can come from, with a name for the picture.
    ///
    /// The `switch` is exhaustive and has no `default`, so adding a case to
    /// `NotificationPermission` stops this compiling rather than quietly
    /// leaving a banner nobody has ever seen, which is the only completeness
    /// Swift can enforce over an enum carrying an associated value (L113).
    ///
    /// `hasAsked` is true throughout, because that is the only way any of these
    /// reaches the screen: the banner is deliberately silent before the app has
    /// asked, so a run that has not asked yet has nothing to picture.
    static var complainingPermissions: [(name: String, permission: NotificationPermission)] {
        func name(of permission: NotificationPermission) -> String {
            switch permission {
            case .notAsked: return "asked for but never answered"
            case .granted:  return "granted"
            case .refused:  return "refused"
            case .failed:   return "the request itself failed"
            }
        }

        let every: [NotificationPermission] = [
            .notAsked, .granted, .refused,
            .failed("The application is not signed or lacks a bundle identifier"),
        ]
        return every
            .filter { NotificationNotice.message(permission: $0, hasAsked: true) != nil }
            .map { (name(of: $0), $0) }
    }

    /// The filter above decides what is drawn, so it has to be seen keeping
    /// something out as well as letting things through: a filter that admitted
    /// everything, or nothing, would look identical here (L159, L98).
    func testOnlyThePermissionsWithSomethingToSayAreDrawn() {
        let names = Self.complainingPermissions.map(\.name)

        XCTAssertFalse(names.contains("granted"),
                       "a banner is drawn for the state where notifications work, "
                       + "which is the false alarm that teaches somebody to ignore "
                       + "this one")
        XCTAssertEqual(names.count, 3,
                       "the states that complain are \(names), and there are three "
                       + "of them: asked but unanswered, refused, and the request "
                       + "failing")
    }

    /// Every one of them is on the sheet, asked from the type's side.
    ///
    /// The dump counts what it wrote against what it was given, which is a
    /// count compared with itself: dropping the whole group shrinks both sides
    /// and passes (L70). This asks the other question.
    func testEveryNotificationComplaintIsOnTheSheet() {
        let names = states.map(\.name)

        for complaint in Self.complainingPermissions {
            XCTAssertTrue(names.contains { $0.contains(complaint.name) }, """
                Nothing on the review sheet shows the notifications banner for \
                "\(complaint.name)", so a visual change to the one sentence that has \
                to be read while the window is open can only be reviewed by \
                reproducing the permission state by hand.
                """)
        }
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
            measured.append((state.name, try Self.wordShare(of: state)))
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

    /// The memo #1018 put in front of the render, checked against the render.
    ///
    /// Two implementations behind one name are never compared and can drift
    /// apart indefinitely with every caller reading as correct (L263), so this
    /// asks the memo and the direct measurement the same question and requires
    /// the same answer. At BOTH widths, because a memo that ignored width would
    /// agree at the first one it was asked and be wrong at the second.
    func testTheShareMemoAnswersWhatAFreshMeasurementDoes() throws {
        let state = try XCTUnwrap(states.first)
        for width in [CGFloat(520), CGFloat(300)] {
            let fresh = WordFootprint.share(
                try Self.render(state.view, width: width),
                try Self.render(state.view, width: width, wordless: true))
            XCTAssertEqual(try Self.wordShare(of: state, width: width), fresh,
                           accuracy: 0.0001, """
                the memo and a fresh measurement of "\(state.name)" at \(width)pt \
                disagree, so the three sweeps in this file are no longer measuring \
                what they say they are.
                """)
        }
    }

    /// The one way this memo could silently empty a whole test.
    ///
    /// Keyed on the state alone, `testEveryBannerStillDrawsItsMessageWhenNarrow`
    /// would be handed the 520pt answer for all forty surfaces and would stop
    /// measuring the narrow layout entirely, while passing (L98). A count rather
    /// than a comparison of the two numbers, because two widths CAN legitimately
    /// measure the same and a check that assumed otherwise would be flaky.
    func testTheShareMemoIsKeyedByWidthAsWellAsByState() throws {
        let state = try XCTUnwrap(states.first)
        _ = try Self.wordShare(of: state, width: 520)
        _ = try Self.wordShare(of: state, width: 300)

        let kept = Self.measuredShares.keys.filter { $0.state == state.name }
        XCTAssertEqual(kept.count, 2, """
            the memo holds \(kept.count) entries for "\(state.name)" across two \
            widths, so one width is answering for the other and the narrow sweep is \
            re-reading the wide one's numbers.
            """)
    }

    /// A banner is worth nothing if the words run past the edge of it. Rendering
    /// at a narrow width is where a long message with a two button row breaks.
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
            WordFootprint.share(try Self.render(button(colour)),
                                try Self.render(button(colour), wordless: true))
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


    // ── every text-only colour rule has moved out of this file (#1045) ────
    //
    // All four families now live in `tests/test_screens_draw_from_named_colours.py`,
    // over matchers in `tests/swift_colour_rules.py`: the named-colour sweep,
    // the accent rule, the faint tone and its disabled-label exemption, the
    // system colours, the raw type colours with their two file exemptions, and
    // the quiet mark with its owner walk.
    //
    // They read nothing but source text, so they never needed the app build
    // that every registry entry naming this file pays. A diff touching this
    // file re-proved 33 entries at about 29s each; it now re-proves 18.
    //
    // Their fifteen registry entries moved with them, and every one was
    // re-proved against the Python rule BEFORE the Swift side was deleted. The
    // fixtures moved verbatim, because the tree is clean and they are the only
    // thing that can show a matcher did not narrow in the move (L48, L159,
    // L263): the wrapped ternary at both widths, the `-> Color` helper both
    // branching and as one expression, the bracket inside a sentence, the
    // checkbox whose label sits under the icon, and the decorative separator
    // that says nobody reads it.
    //
    // The rules BELOW still render or still read Swift types, so they stay.


    // MARK: - Every colour drawn as type, not just the two that were caught (#620)


    // MARK: - The quiet tone only ever dresses a mark (#629)


    // MARK: - The faint tone (#611)


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
        let spinnerOnly = WordFootprint.ink(try Self.render(ProgressView().frame(height: 40)))
        XCTAssertGreaterThan(spinnerOnly, Self.legibleInk, """
            A bare ProgressView measured \(String(format: "%.4f", spinnerOnly)), which \
            clears the legibility threshold while drawing no words at all. If this \
            ever stops being true, ImageRenderer has learned to draw it and the \
            states above can carry their menus again.
            """)

        let words = WordFootprint.share(try Self.render(ProgressView().frame(height: 40)),
                                        try Self.render(ProgressView().frame(height: 40),
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
            WordFootprint.share(try Self.render(card(colour)),
                                try Self.render(card(colour), wordless: true))
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
        XCTAssertEqual(WordFootprint.share(try Self.render(state.view),
                                           try Self.render(state.view)),
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
        // has to be found separately. `ReviewSheet` prints where it is.
        //
        // Clearing THIS group rather than the folder (#992). The folder used to
        // be emptied once per test process, which stopped being once per run the
        // moment the suite went parallel: every worker cleared it and the dumps
        // deleted each other's work mid-run.
        try ReviewSheet.begin(group: Self.reviewGroup)

        for state in states {
            try ReviewSheet.write(try Self.render(state.view),
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
