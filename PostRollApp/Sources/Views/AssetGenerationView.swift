import SwiftUI
import AppKit

struct AssetGenerationView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(GenerationManager.self) private var genManager

    /// When no run is active, this picks between the configuring and done
    /// screens. `nil` defers to `event.weekResult` (done if results exist).
    /// "Regenerate all" sets it to force the configuring screen.
    @State private var forceConfigure = false

    init(event: Event) {
        self.event = event
    }

    // Animation state
    @State private var showCheckmark = false
    @State private var phasesVisible = false

    // Program PDF download error, surfaced as an alert when non-nil.
    @State private var programPDFError: String?
    // True while a program PDF is being rebuilt on demand (OCR runs off-main).
    @State private var isPreparingProgramPDF = false


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

    // Phase timeline — full run uses the rolling-window history from TimingStore;
    // retries build a smaller, retry-specific timeline so the UI reflects reality.
    private var scaledPhases: [(name: String, startsAt: Int)] {
        retryPhases?.phases ?? TimingStore.shared.scaledGenerationPhases()
    }

    private var estimatedTotalFormatted: String {
        if let retry = retryPhases {
            return TimingStore.formatClock(retry.estimate)
        }
        if let est = TimingStore.shared.generationEstimate {
            return TimingStore.formatClock(est)
        }
        return "~6:00"
    }

    /// Returns retry-specific phase timeline when `retryDays` is set. Caption and
    /// blog means come from TimingStore if available; otherwise fall back to a
    /// proportion of the full-run estimate.
    private var retryPhases: (phases: [(name: String, startsAt: Int)], estimate: Double)? {
        guard let retry = activeRetryDays else { return nil }

        let fullEstimate = TimingStore.shared.generationEstimate ?? 360
        let captionsMean = TimingStore.shared.captionsMean ?? (fullEstimate * 0.50)
        let blogMean     = TimingStore.shared.blogMean     ?? (fullEstimate * 0.25)
        let totalDayCount = max(1, daysWithPhotos.count)

        let retryDayKeys = retry.subtracting(["blog"])
        let hasBlog = retry.contains("blog")

        let perDay = captionsMean / Double(totalDayCount)
        let retryCaptionsTotal = perDay * Double(max(1, retryDayKeys.count))

        var phases: [(name: String, startsAt: Int)] = []
        var cursor = 0

        if !retryDayKeys.isEmpty {
            let sortedDayNames = DayName.allCases
                .filter { retryDayKeys.contains($0.rawValue) }
                .map { $0.displayName }
            phases.append(("Re-reading photos", cursor))
            cursor += 5
            phases.append(("Writing \(joinNames(sortedDayNames)) captions", cursor))
            cursor += Int(retryCaptionsTotal.rounded())
        }

        if hasBlog {
            phases.append(("Drafting blog post", cursor))
            cursor += Int(blogMean.rounded())
        }

        return (phases, Double(cursor))
    }

    private func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) + \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head) + \(names.last!)"
        }
    }

    /// One-line subtitle shown above the phase timeline so the user knows whether
    /// this is a full run or a partial retry.
    private var runningSubtitle: String {
        guard let retry = activeRetryDays else {
            let count = daysWithPhotos.count
            return "Generating all \(count) \(count == 1 ? "day" : "days")"
        }
        let dayKeys = retry.subtracting(["blog"])
        let dayNames = DayName.allCases
            .filter { dayKeys.contains($0.rawValue) }
            .map { $0.displayName }
        let hasBlog = retry.contains("blog")

        if dayNames.isEmpty && hasBlog { return "Retrying blog post" }
        if hasBlog { return "Retrying \(joinNames(dayNames)) + blog" }
        return "Retrying \(joinNames(dayNames))"
    }

    private var activePhaseIndex: Int {
        var active = 0
        for (i, phase) in scaledPhases.enumerated() {
            if elapsedSeconds >= phase.startsAt { active = i }
        }
        return active
    }

    private func phaseState(for index: Int) -> PhaseState {
        index < activePhaseIndex  ? .completed :
        index == activePhaseIndex ? .active    : .pending
    }

    private var canGenerate: Bool {
        totalPhotoCount > 0
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

                // Summary row
                GenerationSummaryRow(
                    daysCount: daysWithPhotos.count,
                    totalPhotos: totalPhotoCount,
                    hasBlog: !event.blogPhotoPaths.isEmpty
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.lg)

                VStack(alignment: .trailing, spacing: Spacing.sm) {
                    if !canGenerate {
                        Text("Add photos to at least one day to generate.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                    HStack {
                        Spacer()
                        Button("Generate All") { startGeneration() }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(!canGenerate)
                    }
                }
                .padding(Spacing.xl)
            }
        }
        .background(Color.cream)
    }

    // MARK: - Running

    private var phaseColumn: some View {
        VStack(spacing: Spacing.lg) {
            Text(event.name)
                .font(.signPainter(28))
                .foregroundStyle(Color.warmDark)

            Text(runningSubtitle)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
                .textCase(.uppercase)

            // Phase timeline
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(scaledPhases.enumerated()), id: \.offset) { i, phase in
                    PhaseRow(name: phase.name, state: phaseState(for: i))
                        .opacity(phasesVisible ? 1 : 0)
                        .offset(y: phasesVisible ? 0 : 6)
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.82)
                            .delay(Double(i) * 0.07),
                            value: phasesVisible
                        )
                }
            }
            .animation(.easeOut(duration: 0.3), value: activePhaseIndex)
            .padding(.vertical, Spacing.sm)

            // Elapsed clock
            HStack(spacing: Spacing.xs) {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                Text(elapsedFormatted)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Text("/ \(estimatedTotalFormatted)")
                    .font(.light(12))
            }
            .foregroundStyle(Color.warmMid)

            Button("Cancel") {
                cancelGeneration()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.warmMid.opacity(0.7))
            .padding(.top, Spacing.sm)
        }
    }

    private var runningView: some View {
        ZStack {
            Color.cream.ignoresSafeArea()
            phaseColumn
                .frame(maxWidth: 380)
        }
        .background(Color.cream)
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

                BrandBanner(icon: "hourglass", message: halted.reason, style: .warning)
                    .padding(.horizontal, Spacing.xl)

                // What survived, said plainly. Without this the screen reads as
                // a total loss and Dan re-runs work he already has.
                Text(halted.finishedDays.isEmpty
                     ? "The run stopped before any day finished, so there is nothing to keep yet."
                     : "Finished and saved: "
                       + halted.finishedDays.map { $0.rawValue.capitalized }
                                            .joined(separator: ", ") + ".")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.warmMid)
                    .padding(.horizontal, Spacing.xl)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(halted.choices, id: \.self) { choice in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            // The paid route carries the emphasised style so the
                            // two are not offered as if equivalent. Spending
                            // money should look like the deliberate one.
                            if choice.spendsMoney {
                                Button(choice.label) { take(choice) }
                                    .buttonStyle(BrandButtonStyle())
                            } else {
                                Button(choice.label) { take(choice) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.warmMid)
                            }
                            Text(choice.explanation)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.warmMid)
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xl)
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

                BrandBanner(icon: "exclamationmark.triangle", message: message, style: .error)
                    .padding(.horizontal, Spacing.xl)

                HStack(spacing: Spacing.md) {
                    Spacer()
                    if event.weekResult != nil {
                        Button("Use previous results") {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                genManager.clearOutcome(eventID: event.id)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmMid)
                    }
                    Button("Fix inputs") {
                        genManager.clearOutcome(eventID: event.id)
                        goFixInputs()
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.roseGold)
                    Button("Try Again") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            forceConfigure = true
                            genManager.clearOutcome(eventID: event.id)
                        }
                    }
                    .buttonStyle(BrandButtonStyle())
                }
                .padding(Spacing.xl)
            }
        }
        .background(Color.cream)
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
        if ProgramPDFBakery.shared.isBaking(event.id) { return "Building program PDF…" }
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

    private func failedDayLabel(_ key: String) -> String {
        switch key {
        case "blog": return "Blog post"
        case PreviewMergePolicy.graphicsRunKey: return "Visual assets"
        default: return key.capitalized
        }
    }

    private var failedDaysSummary: String {
        let labels = failedDayKeys.map { failedDayLabel($0) }
        switch labels.count {
        case 0: return ""
        case 1: return labels[0]
        case 2: return "\(labels[0]) and \(labels[1])"
        default:
            let allButLast = labels.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(labels.last!)"
        }
    }

    /// Pick an actionable summary for a Python-side error and decide whether
    /// the photographer can resolve it by re-editing inputs. The displayed
    /// message always includes the raw error so Dan can see what actually
    /// happened — the summary is a hint, not a replacement.
    private func humanizeError(day: String, raw: String) -> (text: String, fixable: Bool) {
        let (summary, fixable) = humanizeSummary(day: day, raw: raw)
        if summary.isEmpty {
            return (raw, fixable)
        }
        return ("\(summary)\n\nRaw: \(raw)", fixable)
    }

    /// Returns just the actionable summary — no raw error appended. Empty
    /// string when we don't have a useful translation.
    private func humanizeSummary(day: String, raw: String) -> (text: String, fixable: Bool) {
        let lower = raw.lowercased()

        // ffmpeg / system-level issues — not fixable from the GUI
        if lower.contains("ffmpeg") {
            return ("ffmpeg isn't installed. Run `brew install ffmpeg` in Terminal, then retry.", false)
        }
        if lower.contains("jamendo") || lower.contains("jamendo_client_id") {
            return ("Couldn't reach Jamendo for background audio. Check your JAMENDO_CLIENT_ID env var or upload your own audio file.", false)
        }

        // Claude API errors — distinguish between distinct failure modes.
        // Matches must be specific enough that an "anthropic" mention in a
        // stack-trace doesn't get mis-classified as an auth failure.
        if lower.contains("request_too_large") || lower.contains("413") {
            return ("\(failedDayLabel(day)) sent too much data to Claude in one request. Reduce inputs (fewer photos, shorter notes) and retry.", true)
        }
        if lower.contains("rate_limit") || lower.contains("429") {
            return ("Hit Claude's rate limit. Wait ~30 seconds and retry — no input changes needed.", false)
        }
        if lower.contains("invalid_api_key") || lower.contains("401") || lower.contains("authentication") {
            return ("Claude API key is invalid or missing. Set ANTHROPIC_API_KEY and retry.", false)
        }
        if lower.contains("overloaded_error") || lower.contains("529") {
            return ("Claude is overloaded right now. Wait a minute and retry — no input changes needed.", false)
        }
        if lower.contains("anthropic api error") {
            return ("Claude API error during \(failedDayLabel(day)). Often resolves on retry.", false)
        }

        // Common input-missing patterns — fixable on the photo-assignment screen
        // Any collage day, and the real floor rather than a Classic-preset
        // literal. Under Balanced a day with its full 4 photos was told it
        // needed 10, which is a message that contradicts the app's own
        // generator (#119, #195).
        if let collageDay = DayName(rawValue: day),
           PostingPreset.current.isCollageCarousel(collageDay),
           lower.contains("collage skipped") || lower.contains("collage_min") {
            return (CollagePhotoSelection.generationShortfallHint(day: collageDay), true)
        }
        if day == "tuesday" && (lower.contains("raw") || lower.contains("edited")) {
            return ("Tuesday's before/after reel needs a RAW + edited photo. Assign them and retry.", true)
        }
        if day == "friday" && (lower.contains("raw") || lower.contains("edited")) {
            return ("Friday's before/after story reuses Tuesday's RAW + edited. Assign them on Tuesday and retry.", true)
        }
        if day == "thursday" && lower.contains("photo") && lower.contains("empty") {
            return ("Thursday's scroll reel needs at least one photo. Add photos to Thursday and retry.", true)
        }
        if lower.contains("no such file") || lower.contains("filenotfounderror") {
            return ("A photo or audio file was moved or deleted. Re-assign your photos on the photo screen and retry.", true)
        }

        if lower.contains("story fallback failed") {
            return ("Even the static-image fallback for \(failedDayLabel(day)) couldn't run. Often fixed by re-uploading the day's photos.", true)
        }

        // No specific summary — caller will display the raw error verbatim.
        return ("", true)
    }

    private struct FailedDayInfo: Identifiable {
        let id: String      // day key
        let label: String
        let message: String
        let fixable: Bool
    }

    private var failedDayInfos: [FailedDayInfo] {
        let failures = allFailures
        return failedDayKeys.compactMap { key in
            guard let raw = failures[key] else { return nil }
            let (text, fixable) = humanizeError(day: key, raw: raw)
            return FailedDayInfo(id: key, label: failedDayLabel(key), message: text, fixable: fixable)
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

        return ScrollView {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.xl)

            Text(event.name)
                .font(.signPainter(28))
                .foregroundStyle(Color.warmDark)

            // A run that never reached the end of the week gets the same hollow
            // mark as one with failures. Python said so on every run and nothing
            // read it, so a week the watchdog cut off looked finished (#262).
            Image(systemName: RunOutcomeNotice.isUnqualifiedSuccess(
                week: liveWeekResult, failedDayCount: errorCount)
                    ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(Color.roseGold.opacity(0.7))
                .scaleEffect(showCheckmark ? 1 : 0.1)
                .opacity(showCheckmark ? 1 : 0)

            Text(RunOutcomeNotice.headline(week: liveWeekResult, failedDayCount: errorCount))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)
                .opacity(showCheckmark ? 1 : 0)
                .offset(y: showCheckmark ? 0 : 8)

            // The verbatim text of a failure the cap detector did not recognise.
            // #258 cannot start until a real cap's wording has been seen, and
            // before this the only place it appeared was stderr (#217, #262).
            if let note = RunOutcomeNotice.unfamiliarFailureNote(week: liveWeekResult) {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmDark.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(Spacing.sm)
                    .background(Color.roseGold.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    .opacity(showCheckmark ? 1 : 0)
            }

            if errorCount > 0 {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(failedDayInfos) { info in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(info.label.uppercased())
                                .font(.system(size: 9, weight: .medium))
                                .tracking(1.1)
                                .foregroundStyle(Color.roseDeep)
                            Text(info.message)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.warmDark)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                        .background(Color.roseDeep.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                }
                .frame(maxWidth: 460)
                .opacity(showCheckmark ? 1 : 0)
            }

            RoseGoldDivider()
                .frame(width: showCheckmark ? 80 : 0)

            VStack(spacing: Spacing.sm) {
                Button("Continue to Review") { advance() }
                    .buttonStyle(BrandButtonStyle())

                if errorCount > 0 {
                    // If any failed day is fixable, give the user a clear path
                    // back to the input screen before retrying.
                    if failedDayInfos.contains(where: \.fixable) {
                        Button("Fix inputs") { goFixInputs() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.roseGold)
                    }
                    Button("Retry \(failedDaysSummary)") {
                        // A graphics failure needs its day's media re-rendered,
                        // which the default partial retry skips: without this the
                        // retry would re-write the caption and leave the missing
                        // collage or reel exactly as missing.
                        let plan = PreviewMergePolicy.retryPlan(
                            failedKeys: Set(failedDayKeys),
                            mediaErrorKeys: Set(event.mediaErrors.keys))
                        startGeneration(retryDays: plan.days,
                                        regenerateGraphics: plan.regenerateGraphics)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
                }

                // Re-roll a single day's caption without nuking the others. Lists
                // every day that has photos assigned. Graphics are not re-rendered
                // (that is what the failure Retry above and the review screen's
                // per-day ↺ are for). Blog and "all" stay as separate shortcuts.
                if !regenerableDayKeys.isEmpty {
                    Menu {
                        ForEach(regenerableDayKeys, id: \.self) { dayKey in
                            Button(regenerableDayLabel(dayKey)) {
                                startGeneration(retryDays: Set([dayKey]))
                            }
                        }
                    } label: {
                        Label("Regenerate one day…", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.roseGold)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if !event.programImagePaths.isEmpty || event.programPDFPath != nil {
                    Button(programPDFButtonLabel) {
                        downloadProgramPDF()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
                    .disabled(isPreparingProgramPDF || ProgramPDFBakery.shared.isBaking(event.id))
                }

                // A failed bake used to be dropped by a `try?`, so the program
                // just stopped existing with nothing said (#80).
                if let bakeError = ProgramPDFBakery.shared.failure(for: event.id) {
                    BrandBanner(
                        icon: "exclamationmark.triangle",
                        message: "The searchable program PDF couldn't be built: \(bakeError). The page scans have been kept.",
                        style: .error,
                        actions: [BrandBannerAction(label: "Try again", action: {
                            ProgramPDFBakery.shared.bake(event: event, appState: appState,
                                                         deletingScansOnSuccess: true)
                        })]
                    )
                }

                if !event.blogPhotoPaths.isEmpty {
                    Button("Regenerate blog post") {
                        startGeneration(retryDays: Set(["blog"]))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmMid)
                }

                Button("Regenerate all") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        forceConfigure = true
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.warmMid)
            }
            .opacity(showCheckmark ? 1 : 0)

            Spacer(minLength: Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cream)
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
        panel.nameFieldStringValue =
            "\(EventExporter.slug(event.org))_\(EventExporter.slug(event.name))_program.pdf"
        panel.title = "Save Program PDF"

        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // Use the cached PDF only when it still matches the current pages — a
        // page added/removed/reordered after the bake makes it stale, so fall
        // through to rebuild.
        let fresh = event.programPDFFingerprint == ProgramPDFBuilder.fingerprint(of: event.programImagePaths)
        if fresh, let prebuilt = event.programPDFPath,
           FileManager.default.fileExists(atPath: prebuilt.path) {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: prebuilt, to: dest)
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

// MARK: - Generation summary row

private struct GenerationSummaryRow: View {
    let daysCount: Int
    let totalPhotos: Int
    let hasBlog: Bool

    var body: some View {
        HStack(spacing: Spacing.xl) {
            SummaryStat(value: "\(daysCount)", label: "DAYS")
            SummaryStat(value: "\(totalPhotos)", label: "PHOTOS")
            if hasBlog {
                SummaryStat(value: "1", label: "BLOG POST")
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.creamDeep)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.creamEdge, lineWidth: 1)
        )
    }
}

private struct SummaryStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.signPainter(26))
                .foregroundStyle(Color.roseGold)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.warmMid)
        }
    }
}

// MARK: - Phase row

private enum PhaseState: Equatable {
    case pending, active, completed
}

private struct PhaseRow: View {
    let name: String
    let state: PhaseState

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.roseGold.opacity(0.5))
                case .active:
                    Image(systemName: "circle.fill")
                        .foregroundStyle(Color.roseGold)
                        .symbolEffect(.pulse)
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(Color.creamEdge)
                }
            }
            .font(.system(size: 12))
            .frame(width: 16, alignment: .center)

            Text(name)
                .font(.system(size: 13, weight: state == .active ? .medium : .regular))
                .foregroundStyle(
                    state == .pending  ? Color.warmMid.opacity(0.5) :
                    state == .active   ? Color.warmDark             : Color.warmMid
                )
        }
        .animation(.easeOut(duration: 0.25), value: state)
    }
}
