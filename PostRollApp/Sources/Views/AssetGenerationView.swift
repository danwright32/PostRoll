import SwiftUI
import AVKit
import UniformTypeIdentifiers

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

    // MARK: Music picker state
    @State private var musicPass: MusicPass = .idle
    @State private var tuesdayCandidates: [TrackCandidate] = []
    @State private var thursdayCandidates: [TrackCandidate] = []
    @State private var tuesdayPickedID: String? = nil
    @State private var thursdayPickedID: String? = nil
    @State private var tuesdayMood: MusicMood = .auto
    @State private var thursdayMood: MusicMood = .auto
    @State private var tuesdaySeenIDs: Set<String> = []
    @State private var thursdaySeenIDs: Set<String> = []
    @State private var musicFetchTask: Task<Void, Never>? = nil
    @State private var nowPlayingID: String? = nil
    @State private var audioPlayer = AVPlayer()
    @State private var musicBlockingReady: Bool = false  // true once initial auto-picks are set (or skipped)

    enum MusicPass: Equatable {
        case idle                // music picker not active (retry run)
        case fetchingTuesday
        case pickingTuesday
        case fetchingThursday
        case pickingThursday
        case done                // both passes finished
    }

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

    @State private var showingMusicFilePicker = false
    @State private var musicFilePickerDay: DayName = .tuesday

    @ViewBuilder
    private var musicPickerColumn: some View {
        if musicPass != .idle {
            MusicPickerPane(
                tuesdayVisible: shouldFetchMusicForTuesday(event: event),
                thursdayVisible: shouldFetchMusicForThursday(event: event),
                musicPass: musicPass,
                tuesdayCandidates: tuesdayCandidates,
                thursdayCandidates: thursdayCandidates,
                tuesdayPickedID: tuesdayPickedID,
                thursdayPickedID: thursdayPickedID,
                tuesdayMood: tuesdayMood,
                thursdayMood: thursdayMood,
                nowPlayingID: nowPlayingID,
                onPick: { day, cand in applyPick(day: day, candidate: cand) },
                onSkip: { day in clearPick(day: day) },
                onPreview: { cand in previewTrack(cand) },
                onRefetchTuesday: refetchTuesday,
                onRefetchThursday: refetchThursday,
                onTuesdayMood: changeTuesdayMood,
                onThursdayMood: changeThursdayMood,
                onConfirm: { confirmMusicPick() },
                onUpload: { day in
                    musicFilePickerDay = day
                    showingMusicFilePicker = true
                }
            )
            .fileImporter(
                isPresented: $showingMusicFilePicker,
                allowedContentTypes: [.audio, .mp3, .aiff,
                                      UTType(filenameExtension: "m4a") ?? .audio,
                                      UTType(filenameExtension: "aac") ?? .audio],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    applyUploadedAudio(day: musicFilePickerDay, url: url)
                }
            }
        }
    }

    private func applyUploadedAudio(day: DayName, url: URL) {
        var saved = appState.events.first(where: { $0.id == event.id }) ?? event
        if saved.days[day.rawValue] != nil {
            saved.days[day.rawValue]!.audioPath = url
            appState.updateEvent(saved)
        }
        if day == .tuesday { tuesdayPickedID = "uploaded" }
        else if day == .thursday { thursdayPickedID = "uploaded" }
    }

    private var runningView: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1100
            ZStack {
                Color.cream.ignoresSafeArea()
                if wide {
                    HStack(alignment: .top, spacing: Spacing.xl) {
                        Spacer(minLength: 0)
                        phaseColumn
                            .frame(maxWidth: 380)
                            .padding(.top, 60)
                        if musicPass != .idle {
                            musicPickerColumn
                                .frame(maxWidth: 420)
                                .padding(.top, 60)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.xl)
                } else {
                    ScrollView {
                        VStack(spacing: Spacing.xl) {
                            Spacer(minLength: 40)
                            phaseColumn
                            if musicPass != .idle {
                                musicPickerColumn
                                    .frame(maxWidth: 460)
                                    .padding(.horizontal, Spacing.lg)
                            }
                            Spacer(minLength: 40)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .background(Color.cream)
        .onAppear { phasesVisible = true }
        .onDisappear {
            stopTimer()
            phasesVisible = false
            audioPlayer.pause()
            nowPlayingID = nil
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

    private var doneView: some View {
        let errorCount = failedDayKeys.count

        return VStack(spacing: Spacing.lg) {
            Spacer()

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
                Text("\(failedDaysSummary) failed to generate.")
                    .font(.light(12))
                    .foregroundStyle(Color.warmMid)
                    .multilineTextAlignment(.center)
                    .opacity(showCheckmark ? 1 : 0)
            }

            RoseGoldDivider()
                .frame(width: showCheckmark ? 80 : 0)

            VStack(spacing: Spacing.sm) {
                Button("Continue to Review") { advance() }
                    .buttonStyle(BrandButtonStyle())

                if errorCount > 0 {
                    Button("Retry \(failedDaysSummary)") {
                        retryDays = Set(failedDayKeys)
                        startGeneration()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
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

            Spacer()
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

        // Reset music state each run
        tuesdayCandidates = []
        thursdayCandidates = []
        tuesdayPickedID = nil
        thursdayPickedID = nil
        tuesdaySeenIDs = []
        thursdaySeenIDs = []
        tuesdayMood = .auto
        thursdayMood = .auto
        musicBlockingReady = false
        musicPass = (onlyDays == nil) ? .fetchingTuesday : .idle

        // Kick off music picker sequence (Tuesday → Thursday). Skipped on retry runs
        // since the user is only regenerating captions/blog, not reels.
        if onlyDays == nil {
            musicFetchTask?.cancel()
            musicFetchTask = Task { await runMusicPickerSequence(event: ev) }
        } else {
            musicBlockingReady = true
        }

        generationTask = Task {
            // Graphics generation uses the picked audio, so wait until the user has had
            // at least a moment to auto-pick the initial tracks (captions run in parallel).
            let graphicsTask: Task<[String: [String: String]]?, Never>? = onlyDays == nil
                ? Task {
                    await waitForInitialMusicPicks()
                    // Read the freshest event state so the manifest includes the picks.
                    let latest = await MainActor.run { () -> Event in
                        appState.events.first(where: { $0.id == ev.id }) ?? ev
                    }
                    return try? await PythonBridge.shared.runPreviewGeneration(event: latest)
                }
                : nil

            do {
                let result = try await PythonBridge.shared.runWeekGeneration(event: ev, onlyDays: onlyDays)

                // Captions done — now collect graphics (likely already finished in parallel)
                let mediaPaths = await graphicsTask?.value

                await MainActor.run {
                    stopTimer()
                    TimingStore.shared.recordGeneration(seconds: Double(elapsedSeconds))
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
                    musicFetchTask?.cancel()
                    audioPlayer.pause()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        generationState = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Music picker sequence

    /// Walks Tuesday (edit reel) then Thursday (scroll reel). Each pass fetches 5
    /// candidates from Jamendo, auto-selects the first one, and persists it to
    /// `PostingDay.audioPath` so graphics generation can pick it up. Skipped days
    /// (no photos, no raw/edited image for Tuesday's speed edit) advance immediately.
    private func runMusicPickerSequence(event ev: Event) async {
        // Tuesday — only if we actually have the inputs needed for the speed edit reel.
        if shouldFetchMusicForTuesday(event: ev) {
            await MainActor.run { musicPass = .fetchingTuesday }
            await fetchTuesdayCandidates(event: ev, resetSeen: true)
            await MainActor.run {
                if let first = tuesdayCandidates.first {
                    applyPick(day: .tuesday, candidate: first)
                }
                musicPass = .pickingTuesday
            }
            // Wait for user to confirm Tuesday pick before advancing.
            await waitForConfirm()
        }

        // Thursday — only if there are photos for the scroll reel.
        if shouldFetchMusicForThursday(event: ev) {
            await MainActor.run { musicPass = .fetchingThursday }
            await fetchThursdayCandidates(event: ev, resetSeen: true)
            await MainActor.run {
                if let first = thursdayCandidates.first {
                    applyPick(day: .thursday, candidate: first)
                }
                musicPass = .pickingThursday
            }
            // Wait for user to confirm Thursday pick.
            await waitForConfirm()
        }

        await MainActor.run {
            audioPlayer.pause()
            nowPlayingID = nil
            musicPass = .done
            musicBlockingReady = true
        }
    }

    /// Set by the confirm button; cleared by waitForConfirm after it fires.
    @State private var musicConfirmed = false

    private func confirmMusicPick() {
        audioPlayer.pause()
        nowPlayingID = nil
        musicConfirmed = true
    }

    private func waitForConfirm() async {
        await MainActor.run { musicConfirmed = false }
        let deadline = Date().addingTimeInterval(300) // safety timeout
        while await MainActor.run(body: { !musicConfirmed }) {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Blocks graphics generation until either (a) the initial auto-picks are in, or
    /// (b) a safety timeout elapses. This way the preview manifest sees the user's
    /// chosen audio the first time around.
    private func waitForInitialMusicPicks() async {
        let deadline = Date().addingTimeInterval(60)
        while await MainActor.run(body: { !musicBlockingReady }) {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func shouldFetchMusicForTuesday(event ev: Event) -> Bool {
        guard let pd = ev.days[DayName.tuesday.rawValue] else { return false }
        // A reel is generated whenever raw + edited photos exist — either a screen
        // recording timelapse or a slider/morph reel. Both need audio.
        return pd.rawPhotoPath != nil && pd.editedPhotoPath != nil
    }

    private func shouldFetchMusicForThursday(event ev: Event) -> Bool {
        guard let pd = ev.days[DayName.thursday.rawValue] else { return false }
        return !pd.photoPaths.isEmpty
    }

    /// Tuesday defaults to ambient/cinematic framing since the speed edit reel
    /// doesn't have program content to key off of.
    private var tuesdayAutoTags: String { "ambient,atmospheric" }

    /// Thursday defaults to program-derived tags (sacred/orchestral/jazz/etc).
    /// We approximate Python's `_derive_audio_tags` on the Swift side so the first
    /// fetch matches what Python would pick if we didn't override.
    private var thursdayAutoTags: String {
        let pieces = event.ocrResult?.pieces ?? []
        let text = pieces
            .map { "\($0.title) \($0.composer)" }
            .joined(separator: " ")
            .lowercased()

        let sacredKeywords = [
            "gospel", "praise", "hymn", "church", "sacred", "amen", "hallelujah",
            "spiritual", "requiem", "kyrie", "sanctus", "mass ", "motet", "anthem",
            "cantata", "gloria", "agnus dei", "pie jesu", "magnificat",
        ]
        let jazzKeywords = ["jazz", "blues", "swing", "bebop", "ellington", "coltrane"]
        let orchestralKeywords = [
            "symphony", "concerto", "orchestra", "beethoven", "mozart", "brahms",
            "tchaikovsky", "mahler", "strauss", "bach", "handel", "haydn",
        ]

        if sacredKeywords.contains(where: text.contains) { return "inspirational,orchestral" }
        if jazzKeywords.contains(where: text.contains)   { return "jazz" }
        if orchestralKeywords.contains(where: text.contains) { return "orchestral,classical" }
        return "ambient,atmospheric"
    }

    private func fetchTuesdayCandidates(event ev: Event, resetSeen: Bool) async {
        let tags = tuesdayMood.tags(autoTags: tuesdayAutoTags)
        let exclude = Array(tuesdaySeenIDs)
        do {
            let tracks = try await PythonBridge.shared.runFetchTrackCandidates(
                tags: tags, count: 5, excludeIds: exclude
            )
            await MainActor.run {
                if resetSeen { tuesdaySeenIDs = [] }
                tuesdayCandidates = tracks
                for t in tracks { tuesdaySeenIDs.insert(t.id) }
            }
        } catch {
            await MainActor.run { tuesdayCandidates = [] }
        }
    }

    private func fetchThursdayCandidates(event ev: Event, resetSeen: Bool) async {
        let tags = thursdayMood.tags(autoTags: thursdayAutoTags)
        let exclude = Array(thursdaySeenIDs)
        do {
            let tracks = try await PythonBridge.shared.runFetchTrackCandidates(
                tags: tags, count: 5, excludeIds: exclude
            )
            await MainActor.run {
                if resetSeen { thursdaySeenIDs = [] }
                thursdayCandidates = tracks
                for t in tracks { thursdaySeenIDs.insert(t.id) }
            }
        } catch {
            await MainActor.run { thursdayCandidates = [] }
        }
    }

    /// Persist a user's (or auto-) pick to `PostingDay.audioPath` so the preview
    /// manifest picks it up. Runs on the main actor.
    private func applyPick(day: DayName, candidate: TrackCandidate) {
        var saved = appState.events.first(where: { $0.id == event.id }) ?? event
        if saved.days[day.rawValue] != nil {
            saved.days[day.rawValue]!.audioPath = candidate.localURL
            appState.updateEvent(saved)
        }
        if day == .tuesday { tuesdayPickedID = candidate.id }
        else if day == .thursday { thursdayPickedID = candidate.id }
    }

    /// Clear a pick so Python falls back to its derived audio.
    private func clearPick(day: DayName) {
        var saved = appState.events.first(where: { $0.id == event.id }) ?? event
        if saved.days[day.rawValue] != nil {
            saved.days[day.rawValue]!.audioPath = nil
            appState.updateEvent(saved)
        }
        if day == .tuesday { tuesdayPickedID = nil }
        else if day == .thursday { thursdayPickedID = nil }
    }

    private func previewTrack(_ candidate: TrackCandidate) {
        if nowPlayingID == candidate.id {
            audioPlayer.pause()
            nowPlayingID = nil
            return
        }
        audioPlayer.replaceCurrentItem(with: AVPlayerItem(url: candidate.localURL))
        audioPlayer.play()
        nowPlayingID = candidate.id
    }

    private func refetchTuesday() {
        let ev = appState.events.first(where: { $0.id == event.id }) ?? event
        Task {
            await MainActor.run { musicPass = .fetchingTuesday }
            await fetchTuesdayCandidates(event: ev, resetSeen: false)
            await MainActor.run {
                if let first = tuesdayCandidates.first {
                    applyPick(day: .tuesday, candidate: first)
                }
                musicPass = .pickingTuesday
            }
        }
    }

    private func refetchThursday() {
        let ev = appState.events.first(where: { $0.id == event.id }) ?? event
        Task {
            await MainActor.run { musicPass = .fetchingThursday }
            await fetchThursdayCandidates(event: ev, resetSeen: false)
            await MainActor.run {
                if let first = thursdayCandidates.first {
                    applyPick(day: .thursday, candidate: first)
                }
                musicPass = .pickingThursday
            }
        }
    }

    private func changeTuesdayMood(_ mood: MusicMood) {
        guard mood != tuesdayMood else { return }
        tuesdayMood = mood
        tuesdaySeenIDs = []
        refetchTuesday()
    }

    private func changeThursdayMood(_ mood: MusicMood) {
        guard mood != thursdayMood else { return }
        thursdayMood = mood
        thursdaySeenIDs = []
        refetchThursday()
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        musicFetchTask?.cancel()
        musicFetchTask = nil
        audioPlayer.pause()
        nowPlayingID = nil
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

// MARK: - Music mood

/// Preset moods the user can pick from during music fetching. Each resolves
/// to a Jamendo tag combination verified to return usable instrumental tracks.
/// `.auto` defers to per-day defaults (Tuesday = ambient, Thursday = program-derived).
enum MusicMood: String, CaseIterable, Identifiable {
    case auto
    case ambient
    case orchestral
    case jazz
    case gospel
    case spiritual
    case choral

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:       return "Auto"
        case .ambient:    return "Ambient"
        case .orchestral: return "Orchestral"
        case .jazz:       return "Jazz"
        case .gospel:     return "Gospel"
        case .spiritual:  return "Spiritual"
        case .choral:     return "A Cappella"
        }
    }

    /// Returns the Jamendo tag string for this mood. `.auto` uses per-day defaults
    /// passed via `autoTags`.
    func tags(autoTags: String) -> String {
        switch self {
        case .auto:       return autoTags
        case .ambient:    return "ambient,atmospheric"
        case .orchestral: return "orchestral,classical"
        case .jazz:       return "jazz"
        case .gospel:     return "gospel"
        case .spiritual:  return "spiritual"
        case .choral:     return "choir,acapella"
        }
    }
}

// MARK: - Music picker pane

/// Side panel shown during generation. Walks the user through picking audio for
/// Tuesday's edit reel then Thursday's scroll reel. Each pass shows 5 candidates
/// from Jamendo with play-preview buttons, a mood override chip row, and a
/// "get new tracks" refresh button.
private struct MusicPickerPane: View {
    let tuesdayVisible: Bool
    let thursdayVisible: Bool
    let musicPass: AssetGenerationView.MusicPass
    let tuesdayCandidates: [TrackCandidate]
    let thursdayCandidates: [TrackCandidate]
    let tuesdayPickedID: String?
    let thursdayPickedID: String?
    let tuesdayMood: MusicMood
    let thursdayMood: MusicMood
    let nowPlayingID: String?
    let onPick: (DayName, TrackCandidate) -> Void
    let onSkip: (DayName) -> Void
    let onPreview: (TrackCandidate) -> Void
    let onRefetchTuesday: () -> Void
    let onRefetchThursday: () -> Void
    let onTuesdayMood: (MusicMood) -> Void
    let onThursdayMood: (MusicMood) -> Void
    let onConfirm: () -> Void
    let onUpload: (DayName) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("WHILE YOU WAIT — PICK REEL MUSIC")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.warmMid)

            if tuesdayVisible {
                section(
                    title: "Tuesday — Edit Reel",
                    day: .tuesday,
                    active: musicPass == .fetchingTuesday || musicPass == .pickingTuesday,
                    showConfirm: musicPass == .pickingTuesday,
                    mood: tuesdayMood,
                    candidates: tuesdayCandidates,
                    pickedID: tuesdayPickedID,
                    isFetching: musicPass == .fetchingTuesday,
                    onMood: onTuesdayMood,
                    onRefetch: onRefetchTuesday,
                    onPick: { onPick(.tuesday, $0) },
                    onSkip: { onSkip(.tuesday) }
                )
            }

            if thursdayVisible {
                section(
                    title: "Thursday — Scroll Reel",
                    day: .thursday,
                    active: musicPass == .fetchingThursday || musicPass == .pickingThursday || musicPass == .done,
                    showConfirm: musicPass == .pickingThursday,
                    mood: thursdayMood,
                    candidates: thursdayCandidates,
                    pickedID: thursdayPickedID,
                    isFetching: musicPass == .fetchingThursday,
                    onMood: onThursdayMood,
                    onRefetch: onRefetchThursday,
                    onPick: { onPick(.thursday, $0) },
                    onSkip: { onSkip(.thursday) }
                )
            }
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Color.creamDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(Color.creamEdge, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func section(
        title: String,
        day: DayName,
        active: Bool,
        showConfirm: Bool,
        mood: MusicMood,
        candidates: [TrackCandidate],
        pickedID: String?,
        isFetching: Bool,
        onMood: @escaping (MusicMood) -> Void,
        onRefetch: @escaping () -> Void,
        onPick: @escaping (TrackCandidate) -> Void,
        onSkip: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.warmDark : Color.warmMid.opacity(0.6))
                Spacer()
                if active && pickedID != nil && !isFetching {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.roseGold.opacity(0.7))
                }
            }

            if active {
                moodRow(selected: mood, onMood: onMood)

                if isFetching {
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Fetching tracks…")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                    .padding(.vertical, Spacing.xs)
                } else if candidates.isEmpty {
                    Text("No tracks found. Try a different mood.")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                } else {
                    VStack(spacing: 4) {
                        ForEach(candidates) { cand in
                            TrackRow(
                                candidate: cand,
                                isPicked: cand.id == pickedID,
                                isPlaying: cand.id == nowPlayingID,
                                onTap: { onPick(cand) },
                                onPreview: { onPreview(cand) }
                            )
                        }
                    }
                }

                HStack(spacing: Spacing.sm) {
                    Button(action: onRefetch) {
                        Label("New tracks", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.roseGold)
                    .disabled(isFetching)

                    Button {
                        onUpload(day)
                    } label: {
                        Label("Upload audio", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.roseGold)

                    Spacer()

                    if pickedID != nil {
                        Button("Use default", action: onSkip)
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.warmMid)
                    }
                }
                .padding(.top, Spacing.xs)

                if showConfirm {
                    Button(action: onConfirm) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                            Text(pickedID != nil ? "Confirm & continue" : "Skip & continue")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.cream)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.roseGold)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, Spacing.xs)
                }
            } else {
                Text("Will start after \(title.contains("Tuesday") ? "…" : "Tuesday")")
                    .font(.light(11))
                    .foregroundStyle(Color.warmMid.opacity(0.6))
            }
        }
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(active ? Color.cream : Color.clear)
        )
    }

    private func moodRow(selected: MusicMood, onMood: @escaping (MusicMood) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(MusicMood.allCases) { mood in
                Button(action: { onMood(mood) }) {
                    Text(mood.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(mood == selected ? Color.cream : Color.warmMid)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(mood == selected ? Color.roseGold : Color.creamDeep)
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.creamEdge, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TrackRow: View {
    let candidate: TrackCandidate
    let isPicked: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: onPreview) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.roseGold)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name)
                    .font(.system(size: 12, weight: isPicked ? .medium : .regular))
                    .foregroundStyle(Color.warmDark)
                    .lineLimit(1)
                Text(candidate.artistName)
                    .font(.light(10))
                    .foregroundStyle(Color.warmMid)
                    .lineLimit(1)
            }

            Spacer()

            Text(formatDuration(candidate.duration))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.warmMid)

            if isPicked {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.roseGold)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(isPicked ? Color.roseGold.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
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
