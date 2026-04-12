import SwiftUI

struct CaptionReviewView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var result: WeekGenerationResult
    @State private var expanded: ReviewSection? = .caption(DayName.allCases.first!)

    enum ReviewSection: Equatable {
        case caption(DayName)
        case blog
    }

    init(event: Event) {
        self.event = event
        _result = State(initialValue: event.weekResult ?? WeekGenerationResult())
    }

    var daysWithContent: [DayName] {
        DayName.allCases.filter { result[$0] != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Review Content")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.sm)

                StageBackButton(label: "Back to generation") {
                    var ev = event
                    ev.stage = .assetsGenerated
                    appState.updateEvent(ev)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)

                if result.errorCount > 0 {
                    BrandBanner(
                        icon: "exclamationmark.triangle",
                        message: "\(result.errorCount) day\(result.errorCount == 1 ? "" : "s") failed to generate. You can re-run generation from the previous step."
                    )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)
                }

                ForEach(daysWithContent, id: \.self) { day in
                    let section = ReviewSection.caption(day)
                    CaptionSection(
                        day: day,
                        caption: captionBinding(day),
                        isExpanded: expanded == section,
                        onToggle: { expanded = expanded == section ? nil : section },
                        onRevise: { feedback in
                            try await reviseCaption(day: day, feedback: feedback)
                        }
                    )
                }

                if result.blog != nil {
                    BlogSection(
                        blog: blogBinding,
                        isExpanded: expanded == .blog,
                        onToggle: { expanded = expanded == .blog ? nil : .blog }
                    )
                }

                HStack {
                    Spacer()
                    Button("Approve & Export") { advance() }
                        .buttonStyle(BrandButtonStyle())
                }
                .padding(Spacing.xl)
            }
        }
        .background(Color.cream)
    }

    // MARK: - Bindings

    private func captionBinding(_ day: DayName) -> Binding<DayCaption> {
        Binding(
            get: { result[day] ?? DayCaption() },
            set: { result[day] = $0; save() }
        )
    }

    private var blogBinding: Binding<BlogOutput> {
        Binding(
            get: { result.blog ?? BlogOutput() },
            set: { result.blog = $0; save() }
        )
    }

    // MARK: - Caption revision

    private func reviseCaption(day: DayName, feedback: String) async throws {
        guard let current = result[day] else { return }
        let revised = try await PythonBridge.shared.runCaptionRevision(
            event: event,
            day: day,
            feedback: feedback,
            currentCaption: current
        )
        result[day] = revised
        save()
    }

    // MARK: - Persistence

    private func save() {
        var ev = event
        ev.weekResult = result
        appState.updateEvent(ev)
    }

    private func advance() {
        save()
        var ev = event
        ev.weekResult = result
        ev.stage = .exported
        appState.updateEvent(ev)
    }
}

// MARK: - Caption Section

private struct CaptionSection: View {
    let day: DayName
    @Binding var caption: DayCaption
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRevise: (String) async throws -> Void

    @State private var showingRevision = false
    @State private var feedbackText = ""
    @State private var saveToBrandVoice = false
    @State private var isRevising = false
    @State private var revisionError: String?

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    Text(day.displayName.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)

                    if !caption.caption.isEmpty {
                        Text(String(caption.caption.prefix(40)) + (caption.caption.count > 40 ? "…" : ""))
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                            .lineLimit(1)
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
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ReviewTextArea(label: "Caption", text: $caption.caption, minHeight: 80)

                    HashtagsEditor(hashtags: $caption.hashtags)

                    if !caption.altTexts.isEmpty {
                        AltTextsSection(altTexts: $caption.altTexts)
                    }

                    // Revision panel
                    if showingRevision {
                        RevisionPanel(
                            feedbackText: $feedbackText,
                            saveToBrandVoice: $saveToBrandVoice,
                            isRevising: isRevising,
                            error: revisionError,
                            onApply: { applyRevision() },
                            onCancel: {
                                showingRevision = false
                                feedbackText = ""
                                saveToBrandVoice = false
                                revisionError = nil
                            }
                        )
                    } else {
                        Button("Revise with feedback…") { showingRevision = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.roseGold)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.3)
        }
    }

    private func applyRevision() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRevising = true
        revisionError = nil
        let shouldSave = saveToBrandVoice
        Task {
            do {
                try await onRevise(trimmed)
                if shouldSave {
                    try? PythonBridge.shared.appendBrandVoiceNote(trimmed)
                }
                await MainActor.run {
                    isRevising = false
                    showingRevision = false
                    feedbackText = ""
                    saveToBrandVoice = false
                }
            } catch {
                await MainActor.run {
                    isRevising = false
                    revisionError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Revision panel

private struct RevisionPanel: View {
    @Binding var feedbackText: String
    @Binding var saveToBrandVoice: Bool
    let isRevising: Bool
    let error: String?
    let onApply: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("FEEDBACK FOR REVISION")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.roseGold)

            TextField("e.g. make it shorter, add @dciny, don't mention the scene label", text: $feedbackText)
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
                .disabled(isRevising)
                .onAppear { focused = true }

            Toggle(isOn: $saveToBrandVoice) {
                Text("Save this feedback to brand voice for all future events")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmMid)
            }
            .toggleStyle(.checkbox)
            .disabled(isRevising)

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.sm) {
                if isRevising {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.roseGold)
                    Text("Revising…")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                } else {
                    Button("Apply") { onApply() }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmMid)
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.roseGold.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.roseGold.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Blog Section

private struct BlogSection: View {
    @Binding var blog: BlogOutput
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BLOG POST")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                        if !blog.title.isEmpty {
                            Text(blog.title)
                                .font(.light(11))
                                .foregroundStyle(Color.warmMid)
                                .lineLimit(1)
                        }
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
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ReviewTextArea(label: "Title", text: $blog.title, minHeight: 36)
                    ReviewTextArea(label: "Body (Markdown)", text: $blog.body, minHeight: 280)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            RoseGoldDivider(opacity: 0.3)
        }
    }
}

// MARK: - Hashtags editor

private struct HashtagsEditor: View {
    @Binding var hashtags: [String]

    // Flat editable text — joined with spaces
    @State private var raw: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HASHTAGS")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
            TextField("", text: $raw)
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
                .onChange(of: raw) { _, newVal in
                    hashtags = newVal
                        .split(separator: " ")
                        .map { String($0) }
                        .filter { !$0.isEmpty }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused {
                        // Normalize on blur
                        raw = hashtags.joined(separator: " ")
                    }
                }
        }
        .onAppear { raw = hashtags.joined(separator: " ") }
        .onChange(of: hashtags) { _, tags in
            if !focused {
                raw = tags.joined(separator: " ")
            }
        }
    }
}

// MARK: - Alt texts section

private struct AltTextsSection: View {
    @Binding var altTexts: [String]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text("ALT TEXTS (\(altTexts.count))")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Color.warmMid)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.warmMid)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(altTexts.indices, id: \.self) { i in
                    AltTextRow(index: i, text: $altTexts[i])
                }
            }
        }
    }
}

private struct AltTextRow: View {
    let index: Int
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text("P\(index + 1)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.warmMid)
                .padding(.top, 8)
                .frame(width: 20, alignment: .leading)
            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 11))
                .foregroundStyle(Color.warmDark)
                .focusEffectDisabled()
                .frame(minHeight: 44)
                .scrollContentBackground(.hidden)
                .padding(6)
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

// MARK: - Shared text area

private struct ReviewTextArea: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat = 80
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(Color.warmDark)
                .focusEffectDisabled()
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(Color.creamDeep)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(
                                    focused ? Color.roseGold : Color.creamEdge,
                                    lineWidth: focused ? 1.5 : 1
                                )
                        )
                )
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
