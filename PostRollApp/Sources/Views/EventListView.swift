import SwiftUI

struct EventListView: View {
    @Environment(AppState.self) private var appState
    @Environment(HashtagStore.self) private var hashtagStore
    @State private var recentlyDeleted: Event?
    @State private var recentlyDuplicatedID: Event.ID?
    @State private var showUndoBanner = false
    @State private var undoDismissWork: DispatchWorkItem?
    @State private var searchText = ""
    @State private var showingHashtagSettings = false
    @State private var hoveredEventID: Event.ID?
    @State private var showExported = false
    @Namespace private var selectionNamespace

    private var exportedCount: Int {
        appState.events.filter { $0.stage == .exported }.count
    }

    private var filteredEvents: [Event] {
        let base = showExported ? appState.events : appState.events.filter { $0.stage != .exported }
        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.org.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedEventID) {
            ForEach(filteredEvents) { event in
                let isSelected = appState.selectedEventID == event.id
                let isHovered  = hoveredEventID == event.id && !isSelected

                EventRow(event: event)
                    .tag(event.id)
                    .listRowBackground(
                        Group {
                            if isSelected {
                                // Glider + bookmark strip slide together as one unit
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: Radius.md)
                                        .fill(Color.roseGold.opacity(0.12))
                                    // Bookmark strip — a slim rose-gold spine at the leading edge
                                    Capsule()
                                        .fill(Color.roseGold)
                                        .frame(width: 2.5)
                                        .padding(.vertical, 8)
                                }
                                .matchedGeometryEffect(id: "selectionBG", in: selectionNamespace)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                            } else if isHovered {
                                // Pre-selection warmth — the row glows before the click lands
                                RoundedRectangle(cornerRadius: Radius.md)
                                    .fill(Color.roseGold.opacity(0.05))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                            } else {
                                // Opaque background prevents the system accent-color
                                // selection highlight from bleeding through.
                                Color.creamDeep
                            }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: Spacing.rowV, leading: Spacing.rowInset, bottom: Spacing.rowV, trailing: Spacing.rowInset))
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(Color.creamEdge)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) {
                            hoveredEventID = hovering ? event.id : nil
                        }
                    }
                    .contextMenu {
                        Button("Duplicate") {
                            if let newID = appState.duplicateEvent(id: event.id) {
                                recentlyDuplicatedID = newID
                                recentlyDeleted = nil
                                undoDismissWork?.cancel()
                                withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = true }
                                let work = DispatchWorkItem {
                                    withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = false }
                                    recentlyDuplicatedID = nil
                                }
                                undoDismissWork = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
                            }
                        }
                        .keyboardShortcut("d", modifiers: .command)
                        Divider()
                        Button("Delete", role: .destructive) {
                            if let event = appState.events.first(where: { $0.id == event.id }) {
                                recentlyDeleted = event
                                recentlyDuplicatedID = nil
                                appState.deleteEvent(id: event.id)
                                undoDismissWork?.cancel()
                                withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = true }
                                let work = DispatchWorkItem {
                                    withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = false }
                                    recentlyDeleted = nil
                                }
                                undoDismissWork = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
                            }
                        }
                    }
            }
            .onDeleteCommand {
                if let id = appState.selectedEventID,
                   let event = appState.events.first(where: { $0.id == id }) {
                    recentlyDeleted = event
                    recentlyDuplicatedID = nil
                    appState.deleteEvent(id: id)
                    undoDismissWork?.cancel()
                    withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = true }
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = false }
                        recentlyDeleted = nil
                    }
                    undoDismissWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.creamDeep)
        .animation(.spring(response: 0.32, dampingFraction: 0.76), value: appState.selectedEventID)
        .navigationTitle("")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search events")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: Spacing.sm) {
                    Button {
                        showingHashtagSettings = true
                    } label: {
                        Image(systemName: "tag.circle")
                            .foregroundStyle(Color.warmMid)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Hashtag settings — manage global tags added to every caption, and save preset groups for quick reuse.")
                    .accessibilityLabel("Hashtag settings")

                    if exportedCount > 0 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { showExported.toggle() }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "archivebox")
                                    .foregroundStyle(showExported ? Color.roseGold : Color.warmMid)
                                if !showExported {
                                    Text("\(exportedCount)")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(Color.cream)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.warmMid))
                                        .offset(x: 6, y: -4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(showExported ? "Hide exported events" : "Show \(exportedCount) exported event\(exportedCount == 1 ? "" : "s")")
                        .accessibilityLabel(showExported ? "Hide exported events" : "Show exported events")
                    }

                    Button {
                        appState.showingNewEvent = true
                    } label: {
                        Label("New Event", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.roseGold)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .background(
                                Capsule()
                                    .fill(Color.roseGold.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("New Event (⌘N)")
                }
            }
        }
        .sheet(isPresented: $showingHashtagSettings) {
            HashtagSettingsSheet()
                .environment(hashtagStore)
        }
        .overlay {
            if appState.events.isEmpty {
                EmptySidebarView()
            } else if filteredEvents.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Text("No results for \"\(searchText)\"")
                        .font(.light(12))
                        .foregroundStyle(Color.warmMid)
                    Text("Try clearing the search field.")
                        .font(.light(10))
                        .foregroundStyle(Color.warmMid.opacity(0.65))
                    Button("Clear Search") { searchText = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.roseGold)
                        .padding(.top, Spacing.xs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.creamDeep)
            }
        }
        .overlay(alignment: .bottom) {
            if showUndoBanner {
                UndoBanner(message: {
                    if let id = recentlyDuplicatedID,
                       let name = appState.events.first(where: { $0.id == id })?.name {
                        return "\"\(name)\" duplicated."
                    } else if let name = recentlyDeleted?.name {
                        return "\"\(name)\" deleted."
                    }
                    return "Event deleted."
                }()) {
                    undoDismissWork?.cancel()
                    if let event = recentlyDeleted {
                        appState.addEvent(event)
                    } else if let id = recentlyDuplicatedID {
                        appState.deleteEvent(id: id)
                    }
                    withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = false }
                    recentlyDeleted = nil
                    recentlyDuplicatedID = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: Event

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Event name in SignPainter — the visual thread to the generated assets.
            // Larger size and bottom padding create a clear hierarchy break.
            Text(event.name)
                .font(.signPainter(19))
                .foregroundStyle(Color.warmDark)
                .lineLimit(1)
                .padding(.bottom, 2)

            HStack(spacing: 3) {
                Text(event.org)
                Text("·")
                Text(event.displayDate)
            }
            .font(.light(10))
            .foregroundStyle(Color.warmMid)
            .lineLimit(1)

            HStack(spacing: 5) {
                Image(systemName: event.shootType.systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(event.shootType.rawValue)
                Spacer()
                StagePill(stage: event.stage)
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.warmMid)
            .padding(.top, 2)
        }
        .padding(.vertical, 5)
        // Collapse the three visual sub-rows into one VoiceOver stop with a
        // natural spoken label, avoiding the "·" separator and step-number prefix.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.name), \(event.org), \(event.displayDate), \(event.shootType.rawValue), stage \(event.stage.rawValue)")
    }
}

// MARK: - Stage Pill

struct StagePill: View {
    let stage: EventStage

    private var pillColor: Color {
        switch stage {
        case .created:          return .stageCreated
        case .programUploaded:  return .stageProgramUploaded
        case .ocrDone:          return .stageOCRDone
        case .photosAssigned:   return .stagePhotosAssigned
        case .assetsGenerated:  return .stageAssetsGenerated
        case .captionsReviewed: return .stageCaptionsReviewed
        case .exported:         return .stageExported
        }
    }

    private var tooltipText: String {
        switch stage {
        case .created:          return "Step 1 — Event created. Upload the program PDF to begin."
        case .programUploaded:  return "Step 2 — Program uploaded. Ready to run OCR."
        case .ocrDone:          return "Step 3 — OCR complete. Review extracted text, then assign photos."
        case .photosAssigned:   return "Step 4 — Photos assigned to posting days. Ready to generate assets."
        case .assetsGenerated:  return "Step 5 — Assets generated. Review captions before exporting."
        case .captionsReviewed: return "Step 6 — Captions approved. Ready to export."
        case .exported:         return "Step 7 — Exported. All assets are in the output folder."
        }
    }

    var body: some View {
        Text(stage.rawValue)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(pillColor.opacity(0.14))
            .foregroundStyle(pillColor)
            .clipShape(Capsule())
            .help(tooltipText)
            // Announce as "Stage, Photos Assigned" — not the "3 ·" prefix
            .accessibilityLabel("Stage")
            .accessibilityValue(stage.rawValue)
    }
}

// MARK: - Undo Banner

private struct UndoBanner: View {
    var message: String = "Event deleted."
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.roseGold)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Spacing.sm)
        .background(Color.creamDeep)
        .overlay(Rectangle().fill(Color.creamEdge).frame(height: 0.5), alignment: .top)
    }
}

// MARK: - Hashtag Settings Sheet

struct HashtagSettingsSheet: View {
    @Environment(HashtagStore.self) private var hashtagStore
    @Environment(\.dismiss) private var dismiss

    @State private var globalRaw = ""
    @State private var newPresetName = ""
    @State private var newPresetTags = ""
    @State private var showingAddPreset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("HASHTAG SETTINGS")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color.warmDark)
                Spacer()
                Button("Done") { saveGlobal(); dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.roseGold)
            }
            .padding(Spacing.lg)

            RoseGoldDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    // Global hashtags
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("GLOBAL HASHTAGS")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.roseGold)
                        Text("Added to every caption automatically.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                        TextField("e.g. #dwphotony #nyc #concertphotography", text: $globalRaw)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.warmDark)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.xs)
                                    .fill(Color.creamDeep)
                                    .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                        .strokeBorder(Color.creamEdge, lineWidth: 1))
                            )
                            .onChange(of: globalRaw) { _, _ in saveGlobal() }
                    }

                    // Presets
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("PRESETS")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.roseGold)
                        Text("Apply a saved group of hashtags to any caption with one tap.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)

                        ForEach(hashtagStore.presets) { preset in
                            HStack(alignment: .top, spacing: Spacing.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.warmDark)
                                    Text(preset.tags.joined(separator: " "))
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.warmMid)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button {
                                    hashtagStore.deletePreset(id: preset.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(Color.warmMid)
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                            RoseGoldDivider(opacity: 0.3)
                        }

                        if showingAddPreset {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                TextField("Preset name (e.g. DCINY concert)", text: $newPresetName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.warmDark)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.xs)
                                            .fill(Color.creamDeep)
                                            .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                                .strokeBorder(Color.creamEdge, lineWidth: 1))
                                    )
                                TextField("Tags (space-separated)", text: $newPresetTags)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.warmDark)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.xs)
                                            .fill(Color.creamDeep)
                                            .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                                .strokeBorder(Color.creamEdge, lineWidth: 1))
                                    )
                                HStack(spacing: Spacing.sm) {
                                    Button("Save") {
                                        let tags = newPresetTags
                                            .split(separator: " ")
                                            .map { String($0) }
                                            .filter { !$0.isEmpty }
                                        guard !newPresetName.isEmpty, !tags.isEmpty else { return }
                                        hashtagStore.addPreset(name: newPresetName, tags: tags)
                                        newPresetName = ""
                                        newPresetTags = ""
                                        showingAddPreset = false
                                    }
                                    .buttonStyle(BrandButtonStyle())
                                    .disabled(newPresetName.isEmpty || newPresetTags.trimmingCharacters(in: .whitespaces).isEmpty)
                                    Button("Cancel") {
                                        newPresetName = ""
                                        newPresetTags = ""
                                        showingAddPreset = false
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.warmMid)
                                }
                            }
                            .padding(.top, Spacing.sm)
                        } else {
                            Button("Add preset…") { showingAddPreset = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.roseGold)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(Spacing.lg)
            }
        }
        .frame(width: 440)
        .background(Color.cream)
        .onAppear { globalRaw = hashtagStore.globalTags.joined(separator: " ") }
    }

    private func saveGlobal() {
        hashtagStore.globalTags = globalRaw
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }
        hashtagStore.save()
    }
}

// MARK: - Empty Sidebar

private struct EmptySidebarView: View {
    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "theatermasks")
                .font(.system(size: 28))
                .foregroundStyle(Color.warmMid.opacity(Opacity.subtle))
                .padding(.bottom, 4)
            Text("No events")
                .font(.light(12))
                .foregroundStyle(Color.warmMid)
            Text("Tap New Event or press ⌘N to start.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.creamDeep)
    }
}
