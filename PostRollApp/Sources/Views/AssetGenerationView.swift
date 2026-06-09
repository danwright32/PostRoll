import SwiftUI

struct AssetGenerationView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var generationState: GenState

    init(event: Event) {
        self.event = event
        // Skip straight to done if results already exist (e.g. after app reload)
        _generationState = State(initialValue: event.weekResult != nil ? .done : .configuring)
    }

    // Generation tracking
    @State private var generationTask: Task<Void, Never>? = nil
    @State private var elapsedSeconds: Int = 0
    @State private var elapsedTimer: Timer? = nil
    @State private var retryDays: Set<String>? = nil   // nil = regenerate all

    // Animation state
    @State private var showCheckmark = false
    @State private var phasesVisible = false

    enum GenState {
        case configuring
        case running
        case failed(String)
        case done
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
        guard let retry = retryDays else { return nil }

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
        guard let retry = retryDays else {
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
            errorView(message: message)
                .transition(.asymmetric(insertion: .opacity, removal: .opacity))
        case .done:
            doneView
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.97).combined(with: .opacity),
                    removal: .opacity
                ))
        }
    }

    // MARK: - Configure

    private var configureView: some View {
        ScrollView {

            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Generate Content")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.sm)

                StageBackButton(label: "Back to photo assignment") {
                    var ev = event
                    ev.stage = .photosAssigned
                    appState.updateEvent(ev)
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
        .onDisappear {
            stopTimer()
            phasesVisible = false
        }
    }

    private var elapsedFormatted: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
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
                                generationState = .done
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmMid)
                    }
                    Button("Fix inputs") { goFixInputs() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.roseGold)
                    Button("Try Again") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            generationState = .configuring
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

    private var failedDayKeys: [String] {
        (event.weekResult?.errors.keys)
            .map { Array($0).sorted() } ?? []
    }

    /// Days the user can re-run individually. Includes any day they assigned
    /// photos to (or the Tuesday/Friday RAW+edited pair), in DAY_ORDER. Friday
    /// is included only if Tuesday's RAW+edited are set, since Friday's story
    /// derives from those.
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
        key == "blog" ? "Blog post" : key.capitalized
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
        if day == "wednesday" && (lower.contains("collage skipped") || lower.contains("collage_min")) {
            return ("Collage needs at least 10 photos. Add more photos to Wednesday and retry.", true)
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
        guard let errors = event.weekResult?.errors else { return [] }
        return failedDayKeys.compactMap { key in
            guard let raw = errors[key] else { return nil }
            let (text, fixable) = humanizeError(day: key, raw: raw)
            return FailedDayInfo(id: key, label: failedDayLabel(key), message: text, fixable: fixable)
        }
    }

    /// Send the user back to the photo-assignment stage so they can fix
    /// missing inputs, then return here when they click forward again.
    private func goFixInputs() {
        var ev = event
        ev.stage = .photosAssigned
        appState.updateEvent(ev)
    }

    private var doneView: some View {
        let errorCount = failedDayKeys.count

        return ScrollView {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.xl)

            Text(event.name)
                .font(.signPainter(28))
                .foregroundStyle(Color.warmDark)

            Image(systemName: errorCount > 0 ? "checkmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.roseGold.opacity(0.7))
                .scaleEffect(showCheckmark ? 1 : 0.1)
                .opacity(showCheckmark ? 1 : 0)

            Text(errorCount > 0 ? "Partially generated" : "Content generated")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)
                .opacity(showCheckmark ? 1 : 0)
                .offset(y: showCheckmark ? 0 : 8)

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
                        retryDays = Set(failedDayKeys)
                        startGeneration()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
                }

                // Regenerate any single day. Lists every day that has photos
                // assigned (so the user can re-roll captions / graphics for it
                // without nuking the others). Blog and "all" stay as separate
                // shortcuts below.
                if !regenerableDayKeys.isEmpty {
                    Menu {
                        ForEach(regenerableDayKeys, id: \.self) { dayKey in
                            Button(regenerableDayLabel(dayKey)) {
                                retryDays = Set([dayKey])
                                startGeneration()
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

                if !event.blogPhotoPaths.isEmpty {
                    Button("Regenerate blog post") {
                        retryDays = Set(["blog"])
                        startGeneration()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmMid)
                }

                Button("Regenerate all") {
                    retryDays = nil
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        generationState = .configuring
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
    }

    // MARK: - Helpers

    private var totalPhotoCount: Int {
        daysWithPhotos.reduce(0) {
            $0 + (event.days[$1.rawValue]?.photoPaths.count ?? 0)
        } + event.blogPhotoPaths.count
    }

    private func startGeneration() {
        let ev = event

        elapsedSeconds = 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            generationState = .running
        }

        // Elapsed timer fires every second on the main run loop
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { elapsedSeconds += 1 }
        }

        let onlyDays = retryDays

        generationTask = Task {
            // Reels use Python's default background audio. Graphics generation runs
            // in parallel with captions on a full run; retries skip it.
            let graphicsTask: Task<[String: [String: String]]?, Never>? = onlyDays == nil
                ? Task {
                    (try? await PythonBridge.shared.runPreviewGeneration(event: ev))?.paths
                }
                : nil

            do {
                let result = try await PythonBridge.shared.runWeekGeneration(event: ev, onlyDays: onlyDays)

                // Captions done — now collect graphics (likely already finished in parallel)
                let mediaPaths = await graphicsTask?.value

                await MainActor.run {
                    stopTimer()
                    // Only record the run's duration when something actually
                    // generated (caption OR media). Otherwise an immediate
                    // failure pulls the rolling-mean estimate toward zero.
                    let producedSomething = result.hasAnyContent || !(mediaPaths?.isEmpty ?? true)
                    if producedSomething {
                        TimingStore.shared.recordGeneration(seconds: Double(elapsedSeconds))
                    }
                    var saved = ev

                    if let only = onlyDays,
                       var existing = appState.events.first(where: { $0.id == ev.id })?.weekResult ?? ev.weekResult {
                        // Partial retry: merge new results into the existing weekResult
                        for key in only {
                            if key == "blog" {
                                existing.blog = result.blog
                            } else if let day = DayName(rawValue: key) {
                                existing[day] = result[day]
                            }
                        }
                        // Clear retried errors; carry over any new ones
                        for key in only { existing.errors.removeValue(forKey: key) }
                        existing.errors.merge(result.errors) { _, new in new }
                        saved.weekResult = existing
                    } else {
                        saved.weekResult = result
                    }

                    if let paths = mediaPaths, !paths.isEmpty {
                        saved.previewMediaPaths = paths
                    }

                    appState.updateEvent(saved)
                    NotificationService.shared.notifyGenerationComplete(eventName: ev.name)
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        generationState = .done
                    }
                }
            } catch {
                graphicsTask?.cancel()
                await MainActor.run {
                    stopTimer()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        generationState = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        stopTimer()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            generationState = .configuring
        }
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
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
