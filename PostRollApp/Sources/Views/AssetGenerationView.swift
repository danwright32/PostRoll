import SwiftUI

struct AssetGenerationView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var dayHandles: [DayName: String] = [:]   // comma-separated @handles
    @State private var dayNames: [DayName: String] = [:]     // comma-separated plain names
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

    // Phase timeline — timing approximates observed generation durations
    // Phase timeline — delegated to TimingStore so estimates improve with each run.
    private var scaledPhases: [(name: String, startsAt: Int)] {
        TimingStore.shared.scaledGenerationPhases()
    }

    private var estimatedTotalFormatted: String {
        if let est = TimingStore.shared.generationEstimate {
            return TimingStore.formatClock(est)
        }
        return "~6:00"
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
            !(event.days[$0.rawValue]?.photoPaths.isEmpty ?? true)
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
                    var ev = eventWithHandlesSaved()
                    ev.stage = .photosAssigned
                    appState.updateEvent(ev)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)

                BrandBanner(
                    icon: "sparkles",
                    message: "Add @handles for each day if you want to tag accounts. Plain names (no @) go in the second field, for people without Instagram."
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.sm)

                if let prev = previousEventWithHandles {
                    HStack {
                        Spacer()
                        Button("Copy handles from \"\(prev.name)\"") {
                            copyHandlesFromEvent(prev)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.roseGold)
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.sm)
                }

                // Summary row
                GenerationSummaryRow(
                    daysCount: daysWithPhotos.count,
                    totalPhotos: totalPhotoCount,
                    hasBlog: !event.blogPhotoPaths.isEmpty
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.lg)

                // Per-day handle entry
                ForEach(daysWithPhotos, id: \.self) { day in
                    DayHandleSection(
                        day: day,
                        photoCount: event.days[day.rawValue]?.photoPaths.count ?? 0,
                        handles: handleBinding(day),
                        names: namesBinding(day)
                    )
                }

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
        .onAppear { loadHandlesFromModel() }
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Text(event.name)
                .font(.signPainter(28))
                .foregroundStyle(Color.warmDark)

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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cream)
        .onAppear { phasesVisible = true }
        .onDisappear { stopTimer(); phasesVisible = false }
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

    /// Most recent other event that has at least one day with saved handles.
    private var previousEventWithHandles: Event? {
        appState.events
            .filter { $0.id != event.id }
            .sorted { $0.date > $1.date }
            .first { ev in
                ev.days.values.contains { !$0.tagHandles.isEmpty || !$0.nameMentions.isEmpty }
            }
    }

    private func copyHandlesFromEvent(_ source: Event) {
        for day in DayName.allCases {
            guard let pd = source.days[day.rawValue] else { continue }
            if !pd.tagHandles.isEmpty {
                dayHandles[day] = pd.tagHandles.joined(separator: ", ")
            }
            if !pd.nameMentions.isEmpty {
                dayNames[day] = pd.nameMentions.joined(separator: ", ")
            }
        }
    }

    /// Pre-populate handle fields from saved model so returning to this screen
    /// after generation shows previously entered values.
    private func loadHandlesFromModel() {
        for day in daysWithPhotos {
            guard let pd = event.days[day.rawValue] else { continue }
            if !pd.tagHandles.isEmpty {
                dayHandles[day] = pd.tagHandles.joined(separator: ", ")
            }
            if !pd.nameMentions.isEmpty {
                dayNames[day] = pd.nameMentions.joined(separator: ", ")
            }
        }
    }

    private var totalPhotoCount: Int {
        daysWithPhotos.reduce(0) {
            $0 + (event.days[$1.rawValue]?.photoPaths.count ?? 0)
        } + event.blogPhotoPaths.count
    }

    private func handleBinding(_ day: DayName) -> Binding<String> {
        Binding(
            get: { dayHandles[day] ?? "" },
            set: { dayHandles[day] = $0 }
        )
    }

    private func namesBinding(_ day: DayName) -> Binding<String> {
        Binding(
            get: { dayNames[day] ?? "" },
            set: { dayNames[day] = $0 }
        )
    }

    private func parseHandles(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Returns a copy of `event` with current handle/name field values baked in.
    private func eventWithHandlesSaved() -> Event {
        var ev = event
        for day in daysWithPhotos {
            if ev.days[day.rawValue] != nil {
                ev.days[day.rawValue]!.tagHandles   = parseHandles(dayHandles[day] ?? "")
                ev.days[day.rawValue]!.nameMentions = parseHandles(dayNames[day] ?? "")
            }
        }
        return ev
    }

    private func startGeneration() {
        let ev = eventWithHandlesSaved()
        appState.updateEvent(ev)

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
            // Story graphics don't depend on captions — start both at the same time.
            // Skip graphics on partial retries (user is only redoing one day/blog).
            let graphicsTask: Task<[String: [String: String]]?, Never>? = onlyDays == nil
                ? Task { try? await PythonBridge.shared.runPreviewGeneration(event: ev) }
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

// MARK: - Day handle section

private struct DayHandleSection: View {
    let day: DayName
    let photoCount: Int
    @Binding var handles: String
    @Binding var names: String

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    Text(day.displayName.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)

                    Text("\(photoCount) photo\(photoCount == 1 ? "" : "s")")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)

                    if !handles.isEmpty || !names.isEmpty {
                        Image(systemName: "at")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.roseGold.opacity(0.7))
                    }

                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HandleField(
                        label: "@handles (comma-separated)",
                        placeholder: "@dciny, @lincolncenter",
                        text: $handles
                    )
                    HandleField(
                        label: "plain names (no @, comma-separated)",
                        placeholder: "Jordan Langworthy, Maria Smith",
                        text: $names
                    )
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.3)
        }
    }
}

private struct HandleField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.warmMid.opacity(0.30)))
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(Color.warmDark)
                .focusEffectDisabled()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(Color.creamDeep)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.xs)
                                .strokeBorder(
                                    focused ? Color.roseGold : Color.creamEdge,
                                    lineWidth: focused ? 1.5 : 1
                                )
                        )
                )
                .animation(.easeOut(duration: 0.12), value: focused)
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
