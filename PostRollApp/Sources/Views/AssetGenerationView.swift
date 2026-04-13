import SwiftUI

struct AssetGenerationView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var dayHandles: [DayName: String] = [:]   // comma-separated @handles
    @State private var dayNames: [DayName: String] = [:]     // comma-separated plain names
    @State private var generationState: GenState = .configuring

    enum GenState {
        case configuring
        case running
        case failed(String)
        case done
    }

    private var blogPhotoWarning: String? {
        let count = event.blogPhotoPaths.count
        if count > 0 && count < 4 {
            return "Blog post needs 4–7 photos; you have \(count). Add more or remove all to skip."
        }
        if count > 7 {
            return "Blog post needs 4–7 photos; you have \(count). Remove \(count - 7) before generating."
        }
        return nil
    }

    private var canGenerate: Bool {
        totalPhotoCount > 0 && blogPhotoWarning == nil
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
        case .running:
            runningView
        case .failed(let message):
            errorView(message: message)
        case .done:
            doneView
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

                BrandBanner(
                    icon: "sparkles",
                    message: "Add @handles for each day if you want to tag accounts. Plain names (no @) go in the second field — for people without Instagram."
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.sm)

                if let warning = blogPhotoWarning {
                    BrandBanner(icon: "photo.on.rectangle", message: warning, style: .warning)
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

                HStack {
                    Spacer()
                    Button("Generate All") { startGeneration() }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(!canGenerate)
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

            ProgressView()
                .controlSize(.large)
                .tint(Color.roseGold)
                .padding(.vertical, Spacing.sm)

            Text("Generating your content…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)

            Text("This usually takes 3–6 minutes. Keep PostRoll open.")
                .font(.light(12))
                .foregroundStyle(Color.warmMid)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cream)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                EventHeader(event: event, subtitle: "Generation Failed")
                    .padding([.horizontal, .top], Spacing.xl)

                BrandBanner(icon: "exclamationmark.triangle", message: message, style: .error)
                    .padding(.horizontal, Spacing.xl)

                HStack {
                    Spacer()
                    Button("Try Again") { generationState = .configuring }
                        .buttonStyle(BrandButtonStyle())
                }
                .padding(Spacing.xl)
            }
        }
        .background(Color.cream)
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Text(event.name)
                .font(.signPainter(28))
                .foregroundStyle(Color.warmDark)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.roseGold.opacity(0.7))

            Text("Content generated")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)

            RoseGoldDivider()
                .frame(width: 80)

            Button("Continue to Review") { advance() }
                .buttonStyle(BrandButtonStyle())

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cream)
    }

    // MARK: - Helpers

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

    private func startGeneration() {
        // Bake handles and names into the event before generating
        var ev = event
        for day in daysWithPhotos {
            if ev.days[day.rawValue] != nil {
                ev.days[day.rawValue]!.tagHandles   = parseHandles(dayHandles[day] ?? "")
                ev.days[day.rawValue]!.nameMentions = parseHandles(dayNames[day] ?? "")
            }
        }
        appState.updateEvent(ev)

        generationState = .running
        Task {
            do {
                let result = try await PythonBridge.shared.runWeekGeneration(event: ev)
                await MainActor.run {
                    var saved = ev
                    saved.weekResult = result
                    appState.updateEvent(saved)
                    generationState = .done
                }
            } catch {
                await MainActor.run {
                    generationState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func advance() {
        var ev = event
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
            TextField(placeholder, text: $text)
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
