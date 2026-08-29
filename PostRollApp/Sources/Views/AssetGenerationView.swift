import SwiftUI
import AppKit

struct AssetGenerationView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(GenerationManager.self) private var genManager

    /// The two shared stores this screen reads while it DRAWS (#937).
    ///
    /// Injected so the screen can be rendered for review, which nothing could
    /// do before: the phase timeline and the estimate are most of what it says,
    /// and both come from a singleton reached inside a computed property, so
    /// the picture would have been of whatever the run before happened to
    /// leave (L205). The app passes the shared ones and behaves as before.
    ///
    /// Every use of the bakery, not only the ones a render reaches. A seam
    /// applied to the reads while the write still went to the shared instance
    /// would be one screen holding two bakeries, which is the shape of a fix
    /// scoped to the symptom that was noticed (L173).
    let timings: TimingStore
    let bakery: ProgramPDFBakery

    /// When no run is active, this picks between the configuring and done
    /// screens. `nil` defers to `event.weekResult` (done if results exist).
    /// "Regenerate all" sets it to force the configuring screen.
    @State private var forceConfigure = false

    init(event: Event,
         timings: TimingStore = .shared,
         bakery: ProgramPDFBakery = .shared) {
        self.event = event
        self.timings = timings
        self.bakery = bakery
    }

    // Animation state
    @State private var showCheckmark = false
    @State private var phasesVisible = false

    // Program PDF download error, surfaced as an alert when non-nil.
    @State private var programPDFError: String?
    // True while a program PDF is being rebuilt on demand (OCR runs off-main).
    @State private var isPreparingProgramPDF = false
    /// When the current program PDF build started (#460).
    @State private var programPDFStartedAt: Date?


    /// The view's display is derived (not stored): an active/failed run in the
    /// GenerationManager wins; otherwise fall back to configuring vs done.
    /// Keeping this out of `@State` is what lets the run survive the view being
    /// torn down and remounted when the user switches events. See
    /// AssetGenerationDisplay for the pure, unit-tested precedence rule.
    private var generationState: AssetGenerationDisplay {
        AssetGenerationDisplay.resolve(
            runStatus: genManager.run(for: event.id)?.status,
            forceConfigure: forceConfigure,
            hasWeekResult: event.weekResult != nil
        )
    }

    /// Retry scope of the active run (nil = full run), used to shape the
    /// running screen's phase timeline and subtitle.
    private var activeRetryDays: Set<String>? {
        genManager.run(for: event.id)?.retryDays
    }

    private var elapsedSeconds: Int {
        genManager.run(for: event.id)?.elapsedSeconds ?? 0
    }

    // Phase timeline: a full run uses the rolling window history from
    // TimingStore, a retry builds a smaller timeline of its own. The arithmetic
    // for both lives in GenerationRunPlan, where it can be tested (#396).
    private var scaledPhases: [GenerationRunPlan.Phase] {
        retryPlan?.phases ?? timings.scaledGenerationPhases()
            .map { GenerationRunPlan.Phase(name: $0.name, startsAt: $0.startsAt) }
    }

    private var estimatedTotalFormatted: String {
        if let retry = retryPlan {
            return TimingStore.formatClock(retry.estimate)
        }
        if let est = timings.generationEstimate {
            return TimingStore.formatClock(est)
        }
        return "~6:00"
    }

    /// The retry timeline, or nil for a full run. Timings come from TimingStore
    /// here and are passed in, so the plan itself has no singleton to read.
    private var retryPlan: (phases: [GenerationRunPlan.Phase], estimate: Double)? {
        GenerationRunPlan.retryPlan(
            retryDays: activeRetryDays,
            dayCount: daysWithPhotos.count,
            fullEstimate: timings.generationEstimate,
            captionsMean: timings.captionsMean,
            blogMean: timings.blogMean)
    }

    private var runningSubtitle: String {
        GenerationRunPlan.subtitle(retryDays: activeRetryDays,
                                   dayCount: daysWithPhotos.count)
    }

    private var activePhaseIndex: Int {
        GenerationRunPlan.activePhaseIndex(phases: scaledPhases,
                                           elapsedSeconds: elapsedSeconds)
    }

    var daysWithPhotos: [DayName] {
        DayName.allCases.filter {
            $0 != .friday && !(event.days[$0.rawValue]?.photoPaths.isEmpty ?? true)
        }
    }

    var body: some View {
        Group {
            switch generationState {
            case .configuring:
                configureView
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
            case .running:
                runningView
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            case .failed(let message):
                // A week stopped by a usage cap is not a failed week: the days
                // that finished are real, and there are two ways forward rather
                // than only "try again" (#257). An error state and this state
                // are different screens.
                switch FailureScreen.resolve(message: message, week: liveWeekResult) {
                case .halted(let halted):
                    haltedView(halted)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                case .error(let text):
                    errorView(message: text)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                }
            case .done:
                doneView
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        // The generation task deliberately lives in GenerationManager, not this
        // view, so switching events (which remounts this view via .id in
        // EventDetailView) no longer cancels an in-flight run. The write-back
        // re-reads the live event, so a background run can't clobber edits.
    }

    // MARK: - Configure

    private var configureView: some View {
        ScrollView {

            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Generate Content")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.sm)

                StageBackButton(label: "Back to photo assignment") {
                    // Live read, never the captured prop, which is a snapshot from
                    // when this screen was built and reverts anything saved since (#103).
                    if let ev = EventStageTransition.applying(
                            .photosAssigned, toEventWithID: event.id, in: appState.events) {
                        appState.updateEvent(ev)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)

                GenerationConfigureBody(
                    daysCount: daysWithPhotos.count,
                    totalPhotos: totalPhotoCount,
                    hasBlog: !event.blogPhotoPaths.isEmpty,
                    onGenerate: { startGeneration() }
                )
            }
        }
        .background(PaintedSurfaces.page)
    }

    // MARK: - Running

    private var runningView: some View {
        ZStack {
            PaintedSurfaces.page.ignoresSafeArea()
            GenerationRunningBody(
                eventName: event.name,
                subtitle: runningSubtitle,
                phases: scaledPhases,
                activePhaseIndex: activePhaseIndex,
                elapsedFormatted: elapsedFormatted,
                estimatedTotalFormatted: estimatedTotalFormatted,
                revealed: phasesVisible,
                onCancel: { cancelGeneration() }
            )
            .frame(maxWidth: 380)
        }
        .background(PaintedSurfaces.page)
        .onAppear { phasesVisible = true }
        .onDisappear { phasesVisible = false }
    }

    private var elapsedFormatted: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Halted by a usage cap (#257)

    /// Read from the live event rather than the captured prop, so a re-run that
    /// clears the halt stops showing this screen immediately.
    private var liveWeekResult: WeekGenerationResult? {
        (appState.events.first(where: { $0.id == event.id }) ?? event).weekResult
    }

    private func haltedView(_ halted: HaltedWeek) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                EventHeader(event: event, subtitle: "Stopped at the usage limit")
                    .padding([.horizontal, .top], Spacing.xl)

                // Everything below the header is its own view, taking plain
                // values, so the halt screen can be rendered and measured
                // outside the running app (#393).
                HaltedWeekBody(halted: halted, onChoose: take)
            }
        }
    }

    private func take(_ choice: HaltedWeek.Choice) {
        switch choice {
        case .waitForReset:
            // Keep everything and go back to the results, which is what the
            // partial week is for.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                genManager.clearOutcome(eventID: event.id)
            }
        case .finishOnPaidPath:
            // Pinned for THIS run rather than by changing a setting, so paying
            // is the deliberate act it was presented as.
            genManager.clearOutcome(eventID: event.id)
            genManager.start(eventID: event.id, retryDays: nil,
                             appState: appState, forcePaidPath: true)
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                EventHeader(event: event, subtitle: "Generation Failed")
                    .padding([.horizontal, .top], Spacing.xl)

                // Everything below the header is its own view taking plain
                // values, so this screen can be rendered and measured outside
                // the running app (#396).
                GenerationErrorBody(
                    message: message,
                    hasPreviousResults: event.weekResult != nil,
                    onUsePrevious: {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            genManager.clearOutcome(eventID: event.id)
                        }
                    },
                    onFixInputs: {
                        genManager.clearOutcome(eventID: event.id)
                        goFixInputs()
                    },
                    onTryAgain: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            forceConfigure = true
                            genManager.clearOutcome(eventID: event.id)
                        }
                    }
                )
            }
        }
        .background(PaintedSurfaces.page)
    }

    // MARK: - Done

    /// Every failure from the last run, keyed by day. The caption step and the
    /// graphics step fail independently and are stored separately, so a day can
    /// carry one of each (Claude timed out AND the collage died); both messages
    /// show. Graphics failures used to be dropped entirely, which is how a dead
    /// Wednesday collage read as a clean run with no story.
    private var allFailures: [String: String] {
        var combined = event.weekResult?.errors ?? [:]
        for (key, message) in event.mediaErrors {
            combined[key] = combined[key].map { "\($0)\n\(message)" } ?? message
        }
        return combined
    }

    private var failedDayKeys: [String] {
        allFailures.keys.sorted()
    }

    /// Days the user can re-run individually. Includes any day they assigned
    /// photos to (or the Tuesday/Friday RAW+edited pair), in DAY_ORDER. Friday
    /// is included only if Tuesday's RAW+edited are set, since Friday's story
    /// derives from those.
    /// Says which state the program PDF is in, so "Preparing…" isn't shown for
    /// a bake that has already failed and a live bake isn't invisible.
    private var programPDFButtonLabel: String {
        if bakery.isBaking(event.id) { return "Building program PDF…" }
        if isPreparingProgramPDF { return "Preparing program PDF…" }
        return "Download program PDF"
    }

    private var regenerableDayKeys: [String] {
        DayName.allCases.compactMap { day in
            guard let pd = event.days[day.rawValue] else { return nil }
            let hasPhotos = !pd.photoPaths.isEmpty
            let hasReelInputs = pd.rawPhotoPath != nil && pd.editedPhotoPath != nil
            let tuesday = event.days[DayName.tuesday.rawValue]
            let tuesdayReelInputs = (tuesday?.rawPhotoPath != nil && tuesday?.editedPhotoPath != nil)
            switch day {
            case .friday:
                return tuesdayReelInputs ? day.rawValue : nil
            case .tuesday:
                return (hasPhotos || hasReelInputs) ? day.rawValue : nil
            default:
                return hasPhotos ? day.rawValue : nil
            }
        }
    }

    private func regenerableDayLabel(_ key: String) -> String {
        key.capitalized
    }

    /// One card per failed day, with its message produced by
    /// `GenerationFailureText` rather than by this view, so the same words can be
    /// tested and rendered outside the app (#396).
    private var failureCards: [GenerationFailureCard] {
        let failures = allFailures
        return failedDayKeys.compactMap { key in
            guard let raw = failures[key] else { return nil }
            let (text, fixable) = GenerationFailureText.humanize(day: key, raw: raw)
            return GenerationFailureCard(id: key,
                                         label: GenerationFailureText.dayLabel(key),
                                         message: text,
                                         fixable: fixable)
        }
    }

    /// Send the user back to the photo-assignment stage so they can fix
    /// missing inputs, then return here when they click forward again.
    private func goFixInputs() {
        // Live read, never the captured prop, which is a snapshot from
        // when this screen was built and reverts anything saved since (#103).
        if let ev = EventStageTransition.applying(
                .photosAssigned, toEventWithID: event.id, in: appState.events) {
            appState.updateEvent(ev)
        }
    }

    private var doneView: some View {
        let errorCount = failedDayKeys.count
        let cards = failureCards

        return ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: Spacing.xl)

                // The whole screen below the name is its own view taking plain
                // values, so it can be rendered and measured outside the running
                // app (#396). Reaching a run that failed on Thursday, or one the
                // watchdog cut off, is not something a check could do before.
                GenerationDoneBody(
                    eventName: event.name,
                    headline: RunOutcomeNotice.headline(week: liveWeekResult,
                                                        failedDayCount: errorCount),
                    isUnqualifiedSuccess: RunOutcomeNotice.isUnqualifiedSuccess(
                        week: liveWeekResult, failedDayCount: errorCount),
                    unfamiliarNote: RunOutcomeNotice.unfamiliarFailureNote(week: liveWeekResult),
                    failures: cards,
                    regenerableDays: regenerableDayKeys.map {
                        GenerationRegenerableDay(id: $0, label: regenerableDayLabel($0))
                    },
                    programPDFLabel: (!event.programImagePaths.isEmpty || event.programPDFPath != nil)
                        ? programPDFButtonLabel : nil,
                    programPDFDisabled: isPreparingProgramPDF
                        || bakery.isBaking(event.id),
                    programPDFStartedAt: programPDFStartedAt,
                    programBakeError: bakery.failure(for: event.id),
                    hasBlog: !event.blogPhotoPaths.isEmpty,
                    revealed: showCheckmark,
                    onContinue: { advance() },
                    onFixInputs: { goFixInputs() },
                    onRetryFailures: {
                        // A graphics failure needs its day's media re-rendered,
                        // which the default partial retry skips: without this the
                        // retry would re-write the caption and leave the missing
                        // collage or reel exactly as missing.
                        let plan = PreviewMergePolicy.retryPlan(
                            failedKeys: Set(failedDayKeys),
                            mediaErrorKeys: Set(event.mediaErrors.keys))
                        startGeneration(retryDays: plan.days,
                                        regenerateGraphics: plan.regenerateGraphics)
                    },
                    // Re-rolls one day's caption without touching the others.
                    // Graphics are not re-rendered here; that is what the failure
                    // retry above and the review screen's per-day control are for.
                    onRegenerateDay: { dayKey in
                        startGeneration(retryDays: Set([dayKey]))
                    },
                    onDownloadProgramPDF: { downloadProgramPDF() },
                    onRetryProgramBake: {
                        bakery.bake(eventID: event.id, appState: appState,
                                                     deletingScansOnSuccess: true)
                    },
                    onRegenerateBlog: { startGeneration(retryDays: Set(["blog"])) },
                    onRegenerateAll: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            forceConfigure = true
                        }
                    }
                )

                Spacer(minLength: Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaintedSurfaces.page)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) {
                    showCheckmark = true
                }
            }
        }
        .onDisappear { showCheckmark = false }
        .alert("Couldn't export program PDF",
               isPresented: Binding(get: { programPDFError != nil },
                                    set: { if !$0 { programPDFError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(programPDFError ?? "")
        }
    }

    /// Save the whole program as one searchable PDF, then open it in Preview.
    /// Prefers the PDF baked at upload time (which carries the OCR text layer and
    /// outlives the page scans). For legacy events that predate that, or whose
    /// cached PDF is gone, it rebuilds on demand from the page scans.
    private func downloadProgramPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        // The same billing rule as the event's own folder (#689): the
        // organisation when there is one, the venue when there is not, and
        // neither rather than a name that opens with a bare underscore.
        panel.nameFieldStringValue =
            "\(EventFolder.stem(org: event.org, venue: event.venue, name: event.name))_program.pdf"
        panel.title = "Save Program PDF"

        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // Use the cached PDF only when it still matches the current pages — a
        // page added/removed/reordered after the bake makes it stale, so fall
        // through to rebuild.
        let fresh = event.programPDFFingerprint == ProgramPDFBuilder.fingerprint(of: event.programImagePaths)
        if fresh, let prebuilt = event.programPDFPath,
           FileManager.default.fileExists(atPath: prebuilt.path) {
            do {
                // Through the safe swap, not delete-then-copy. `dest` is a path
                // Dan chose himself in a save panel, so it could be any file on
                // his disk, and a failure after the delete used to leave him
                // with neither his file nor the PDF (#445, L5).
                try SafeFileSwap.install(copyOf: prebuilt, at: dest)
                NSWorkspace.shared.open(dest)
            } catch {
                programPDFError = error.localizedDescription
            }
            return
        }

        // No cached PDF — rebuild from the page scans. OCR runs off-main, so show
        // a preparing state until the file is written.
        let pages = event.programImagePaths
        let eventID = event.id
        let cacheURL = AppPaths.programPDFFile(eventID: eventID)
        isPreparingProgramPDF = true
        programPDFStartedAt = Date()
        Task.detached(priority: .userInitiated) {
            do {
                let data = try ProgramPDFBuilder.makePDF(from: pages)
                try data.write(to: dest)
                // Cache it at the canonical path so the next download (and any
                // re-export) is instant and skips re-OCRing the page scans.
                var cached = false
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try data.write(to: cacheURL); cached = true } catch { cached = false }
                let fingerprint = ProgramPDFBuilder.fingerprint(of: pages)
                await MainActor.run {
                    isPreparingProgramPDF = false
                    programPDFStartedAt = nil
                    if cached, var live = appState.events.first(where: { $0.id == eventID }) {
                        live.programPDFPath = cacheURL
                        live.programPDFFingerprint = fingerprint
                        appState.updateEvent(live)
                    }
                    NSWorkspace.shared.open(dest)
                }
            } catch {
                await MainActor.run {
                    isPreparingProgramPDF = false
                    programPDFStartedAt = nil
                    programPDFError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Helpers

    private var totalPhotoCount: Int {
        daysWithPhotos.reduce(0) {
            $0 + (event.days[$1.rawValue]?.photoPaths.count ?? 0)
        } + event.blogPhotoPaths.count
    }

    /// Hand the run off to GenerationManager, which owns it at app scope so it
    /// outlives this view. The success/failure write-back and timing all happen
    /// there; this view just reflects the manager's state.
    private func startGeneration(retryDays: Set<String>? = nil,
                                 regenerateGraphics: Bool? = nil) {
        forceConfigure = false
        genManager.start(eventID: event.id, retryDays: retryDays, appState: appState,
                         regenerateGraphics: regenerateGraphics)
    }

    private func cancelGeneration() {
        genManager.cancel(eventID: event.id)
    }

    private func advance() {
        // Read the current stored event so weekResult is not overwritten with a stale prop.
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.stage = .captionsReviewed
        appState.updateEvent(ev)
    }
}
