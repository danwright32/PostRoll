import SwiftUI

struct OCRReviewView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @State private var ocr: OCRResult
    @State private var expanded: ReviewSection? = .performers

    enum ReviewSection: String, CaseIterable {
        case performers = "Performers"
        case pieces     = "Program"
        case scenes     = "Scenes"
        case notes      = "Notes"
    }

    init(event: Event) {
        self.event = event
        _ocr = State(initialValue: event.ocrResult ?? OCRResult())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Review Program Data")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.sm)

                StageBackButton(label: "Re-upload program") { goBack() }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)

                if let issues = detectedIssues, !issues.isEmpty {
                    BrandBanner(
                        icon: "exclamationmark.circle",
                        message: issues.joined(separator: " ")
                    )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)
                }

                ForEach(ReviewSection.allCases, id: \.self) { section in
                    ReviewSectionRow(
                        title: section.rawValue,
                        isExpanded: expanded == section,
                        onToggle: { expanded = expanded == section ? nil : section }
                    ) {
                        sectionContent(section)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.bottom, Spacing.md)
                    }
                }

                HStack {
                    Spacer()
                    Button("Looks Good") { confirmAndAdvance() }
                        .buttonStyle(BrandButtonStyle())
                }
                .padding(Spacing.xl)
            }
        }
        .background(Color.cream)
    }

    // MARK: - Helpers

    private var detectedIssues: [String]? {
        var issues: [String] = []
        if ocr.performers.isEmpty {
            issues.append("No performers found. Check that the cast list is in your photos.")
        }
        if ocr.pieces.isEmpty {
            issues.append("No works or program listing found.")
        }
        return issues.isEmpty ? nil : issues
    }

    @ViewBuilder
    private func sectionContent(_ section: ReviewSection) -> some View {
        switch section {
        case .performers: PerformersEditor(performers: $ocr.performers)
        case .pieces:     PiecesEditor(pieces: $ocr.pieces)
        case .scenes:     ScenesEditor(scenes: $ocr.scenes)
        case .notes:      NotesEditor(ocr: $ocr)
        }
    }

    private func confirmAndAdvance() {
        var ev = event
        ev.ocrResult = ocr
        ev.ocrReviewDone = true
        ev.stage = .photosAssigned
        appState.updateEvent(ev)
    }

    private func goBack() {
        var ev = event
        ev.stage = .programUploaded
        appState.updateEvent(ev)
    }
}

// MARK: - Section Row

private struct ReviewSectionRow<Content: View>: View {
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
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

            if isExpanded { content() }

            RoseGoldDivider(opacity: 0.3)
        }
    }
}

// MARK: - Performers Editor

private struct PerformersEditor: View {
    @Binding var performers: [Performer]

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach($performers) { $p in
                PerformerRow(performer: $p) {
                    performers.removeAll { $0.id == p.id }
                }
            }
            BrandAddButton(label: "Add Performer") {
                performers.append(Performer())
            }
        }
    }
}

private struct PerformerRow: View {
    @Binding var performer: Performer
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(spacing: 6) {
                HStack(spacing: Spacing.sm) {
                    BrandField("Name", text: $performer.name)
                    BrandField("Role", text: $performer.role).frame(maxWidth: 180)
                }
                BrandField("Voice / Instrument (optional)", text: $performer.voiceOrInstrument)
            }
            Button {
                let query = performer.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? performer.name
                if let url = URL(string: "https://www.google.com/search?q=instagram+\(query)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(performer.name.isEmpty ? Color.creamEdge : Color.warmMid)
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .disabled(performer.name.isEmpty)
            .help("Search Instagram")
            BrandDeleteButton(action: onDelete)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pieces Editor

private struct PiecesEditor: View {
    @Binding var pieces: [Piece]

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach($pieces) { $p in
                PieceRow(piece: $p) { pieces.removeAll { $0.id == p.id } }
            }
            BrandAddButton(label: "Add Work") { pieces.append(Piece()) }
        }
    }
}

private struct PieceRow: View {
    @Binding var piece: Piece
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(spacing: 6) {
                HStack(spacing: Spacing.sm) {
                    BrandField("Composer / Playwright / Artist", text: $piece.composer)
                    BrandField("Title", text: $piece.title)
                }
                BrandField("Notes (optional)", text: $piece.notes)
            }
            BrandDeleteButton(action: onDelete)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Scenes Editor

private struct ScenesEditor: View {
    @Binding var scenes: [ProgramScene]

    var body: some View {
        if scenes.isEmpty {
            Text("No scenes. Normal for concerts; scenes apply to operas and plays.")
                .font(.system(size: 12))
                .foregroundStyle(Color.warmMid)
                .padding(.bottom, Spacing.sm)
        } else {
            VStack(spacing: Spacing.sm) {
                ForEach($scenes) { $s in
                    SceneRow(scene: $s) { scenes.removeAll { $0.id == s.id } }
                }
                BrandAddButton(label: "Add Scene") { scenes.append(ProgramScene()) }
            }
        }
    }
}

private struct SceneRow: View {
    @Binding var scene: ProgramScene
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(spacing: 6) {
                HStack(spacing: Spacing.sm) {
                    BrandField("Scene name", text: $scene.name)
                    BrandField("Location", text: $scene.location)
                }
                BrandField("Visual cues", text: $scene.visualCues)
                BrandField("Description", text: $scene.description)
            }
            BrandDeleteButton(action: onDelete)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Notes Editor

private struct NotesEditor: View {
    @Binding var ocr: OCRResult

    var body: some View {
        VStack(spacing: Spacing.md) {
            BrandTextArea(label: "Organization Notes", text: $ocr.organizationNotes)
            BrandTextArea(label: "Program Notes",      text: $ocr.programNotes)
            BrandTextArea(label: "Venue Notes",        text: $ocr.venueNotes)
            BrandTextArea(label: "Production Details", text: $ocr.productionDetails)
        }
    }
}

private struct BrandTextArea: View {
    let label: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)

            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(Color.warmDark)
                .focusEffectDisabled()
                .frame(minHeight: 72)
                .padding(8)
                .scrollContentBackground(.hidden)
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

// MARK: - Shared editor micro-components

private struct BrandField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    var body: some View {
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

private struct BrandAddButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "plus.circle")
                .font(.system(size: 12))
                .foregroundStyle(Color.roseGold)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

private struct BrandDeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .foregroundStyle(Color.warmMid)
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}
