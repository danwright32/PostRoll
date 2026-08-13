import SwiftUI

struct EventListView: View {
    @Environment(AppState.self) private var appState
    @Environment(HashtagStore.self) private var hashtagStore
    /// Name of the event awaiting undo, kept only for the banner's wording.
    /// The event itself lives in AppState, which owns the undo window and the
    /// media that goes with it.
    @State private var deletedName: String?
    @State private var recentlyDuplicatedID: Event.ID?
    @State private var showUndoBanner = false
    @State private var undoDismissWork: DispatchWorkItem?
    @State private var searchText = ""
    @State private var showingHashtagSettings = false
    @State private var hoveredEventID: Event.ID?
    @State private var showExported = false
    @State private var renamingEventID: Event.ID? = nil
    @State private var renameText = ""
    @Namespace private var selectionNamespace

    private var exportedCount: Int {
        appState.events.filter(\.isExported).count
    }

    private var filteredEvents: [Event] {
        let base = showExported ? appState.events : appState.events.filter { !$0.isExported }
        let searched: [Event]
        if searchText.isEmpty {
            searched = base
        } else {
            searched = base.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.org.localizedCaseInsensitiveContains(searchText)
            }
        }
        return searched.sorted { $0.date > $1.date }
    }

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedEventID) {
            ForEach(filteredEvents) { event in
                let isSelected = appState.selectedEventID == event.id
                let isHovered  = hoveredEventID == event.id && !isSelected

                EventRow(
                        event: event,
                        isSelected: isSelected,
                        isRenaming: renamingEventID == event.id,
                        renameText: $renameText,
                        onRenameCommit: { commitRename(event: event) },
                        onRenameCancel: { renamingEventID = nil }
                    )
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
                        Button("Rename") {
                            renameText = event.name
                            renamingEventID = event.id
                        }
                        Divider()
                        Button("Duplicate") {
                            if let newID = appState.duplicateEvent(id: event.id) {
                                recentlyDuplicatedID = newID
                                deletedName = nil
                                presentUndoBanner { recentlyDuplicatedID = nil }
                            }
                        }
                        .keyboardShortcut("d", modifiers: .command)
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteWithUndo(id: event.id)
                        }
                    }
            }
            .onDeleteCommand {
                if let id = appState.selectedEventID { deleteWithUndo(id: id) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.creamDeep)
        .animation(.spring(response: 0.32, dampingFraction: 0.76), value: appState.selectedEventID)
        .navigationTitle("")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search events")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    Button {
                        showingHashtagSettings = true
                    } label: {
                        Image(systemName: "tag.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.warmMid)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Hashtag settings: manage global tags added to every caption, and save preset groups for quick reuse.")
                    .accessibilityLabel("Hashtag settings")

                    if exportedCount > 0 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { showExported.toggle() }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 14))
                                    .foregroundStyle(showExported ? Color.roseGold : Color.warmMid)
                                    .frame(width: 18, height: 18)
                                if !showExported {
                                    Text("\(exportedCount)")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Color.cream)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 0.5)
                                        .background(Capsule().fill(Color.warmMid))
                                        .offset(x: 4, y: -2)
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
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.roseGold)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("New Event (⌘N)")
                    .accessibilityLabel("New Event")
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
            } else if filteredEvents.isEmpty && !searchText.isEmpty {
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
            } else if filteredEvents.isEmpty && exportedCount > 0 {
                VStack(spacing: Spacing.sm) {
                    Text("All events are archived.")
                        .font(.light(12))
                        .foregroundStyle(Color.warmMid)
                    Button("Show Archived") {
                        withAnimation(.easeOut(duration: 0.2)) { showExported = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.roseGold)
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
                    } else if let deletedName {
                        return "\"\(deletedName)\" deleted."
                    }
                    return "Event deleted."
                }()) {
                    undoDismissWork?.cancel()
                    if deletedName != nil {
                        // AppState still holds the event and has kept its media
                        // on disk for exactly this.
                        appState.undoDelete()
                    } else if let id = recentlyDuplicatedID {
                        appState.deleteEvent(id: id)
                    }
                    withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = false }
                    deletedName = nil
                    recentlyDuplicatedID = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The one delete path. Every entry point (the context menu, the Delete
    /// key, anything added later) goes through here, so none of them can skip
    /// the undo window that keeps the event's media on disk.
    private func deleteWithUndo(id: Event.ID) {
        guard let event = appState.events.first(where: { $0.id == id }) else { return }
        deletedName = event.name
        recentlyDuplicatedID = nil
        appState.deleteEvent(id: id)
        presentUndoBanner { deletedName = nil }
    }

    /// Shows the banner for exactly as long as the undo is actually good for.
    private func presentUndoBanner(onExpire: @escaping () -> Void) {
        undoDismissWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = true }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.2)) { showUndoBanner = false }
            onExpire()
        }
        undoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DeletionPolicy.undoWindow, execute: work)
    }

    private func commitRename(event: Event) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty,
           var ev = appState.events.first(where: { $0.id == event.id }) {
            // Live read (#103): renaming must not revert other saved work.
            ev.name = trimmed
            appState.updateEvent(ev)
        }
        renamingEventID = nil
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: Event
    let isSelected: Bool
    var isRenaming: Bool = false
    @Binding var renameText: String
    var onRenameCommit: (() -> Void)? = nil
    var onRenameCancel: (() -> Void)? = nil

    @Environment(GenerationManager.self) private var genManager
    @Environment(OCRManager.self) private var ocrManager
    @Environment(ExportManager.self) private var exportManager
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if isRenaming {
                TextField("Event name", text: $renameText)
                    .font(.signPainter(19))
                    .foregroundStyle(Color.warmDark)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { onRenameCommit?() }
                    .onExitCommand { onRenameCancel?() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { onRenameCommit?() }
                    }
                    .onAppear { renameFocused = true }
                    .padding(.bottom, 2)
            } else {
                // Event name in SignPainter — the visual thread to the generated assets.
                // Larger size and bottom padding create a clear hierarchy break.
                Text(event.name)
                    .font(.signPainter(19))
                    // Color.primary adapts to selection: white on focused selected rows,
                    // dark on unfocused. Custom warm color only when unselected.
                    .foregroundStyle(isSelected ? Color.primary : Color.warmDark)
                    .lineLimit(1)
                    .padding(.bottom, 2)
            }

            HStack(spacing: 3) {
                Text(event.org)
                Text("·")
                Text(event.displayDate)
            }
            .font(.light(10))
            .foregroundStyle(isSelected ? Color.secondary : Color.warmMid)
            .lineLimit(1)

            HStack(spacing: 5) {
                Image(systemName: event.shootType.systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(event.shootType.rawValue)
                Spacer()
                StagePill(stage: event.stage,
                          awaitingGeneration: event.isAwaitingGeneration,
                          awaitingExport: event.isAwaitingExport,
                          isGenerating: genManager.isRunning(event.id),
                          generationFailed: genManager.hasFailed(event.id),
                          isReading: ocrManager.isRunning(event.id),
                          readingFailed: ocrManager.hasFailed(event.id),
                          isExporting: exportManager.isExporting(event.id),
                          isFinishingMedia: exportManager.isFinishingMedia(event.id),
                          isSelected: isSelected)
            }
            .font(.system(size: 10))
            .foregroundStyle(isSelected ? Color.secondary : Color.warmMid)
            .padding(.top, 2)
        }
        .padding(.vertical, 5)
        // Collapse the three visual sub-rows into one VoiceOver stop with a
        // natural spoken label, avoiding the "·" separator and step-number prefix.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.name), \(event.org), \(event.displayDate), \(event.shootType.rawValue), stage \(event.stage.rawValue)")
        .onChange(of: isRenaming) { _, renaming in
            if renaming { renameFocused = true }
        }
    }
}

// MARK: - Stage Pill

struct StagePill: View {
    let stage: EventStage
    /// True when `stage` has advanced to `.assetsGenerated` purely to open the
    /// generation screen, but no assets exist yet (`weekResult == nil`). The
    /// `stage` field doubles as a navigation router, so it flips the moment the
    /// user hits "Continue to Generation"; without this guard the pill would
    /// claim "Assets Generated" before anything is generated.
    var awaitingGeneration: Bool = false
    /// True when `stage` is `.exported` but the export hasn't actually run yet
    /// (no `exportPath`/`archivedAt`). Like `awaitingGeneration`, this keeps the
    /// pill from claiming "Exported" the instant the user opens the Export screen.
    var awaitingExport: Bool = false
    /// Background work in flight for this event — possibly while the user is off
    /// working on a different event. These override the static stage labels.
    var isGenerating: Bool = false
    var generationFailed: Bool = false
    var isReading: Bool = false
    var readingFailed: Bool = false
    var isExporting: Bool = false
    var isFinishingMedia: Bool = false
    var isSelected: Bool = false

    /// Subtle alive-signal pulse while any background work runs.
    @State private var pulse = false

    private var state: StagePillState {
        StagePillState.resolve(
            stage: stage,
            isGenerating: isGenerating,
            generationFailed: generationFailed,
            isReading: isReading,
            readingFailed: readingFailed,
            isExporting: isExporting,
            isFinishingMedia: isFinishingMedia,
            awaitingGeneration: awaitingGeneration,
            awaitingExport: awaitingExport
        )
    }

    private var pillColor: Color {
        switch state {
        case .reading:            return .roseGold
        case .readingFailed:      return .roseDeep
        case .generating:         return .roseGold
        case .generationFailed:   return .roseDeep
        case .exporting:          return .roseGold
        case .finishingMedia:     return .roseGold
        case .awaitingGeneration: return .stagePhotosAssigned
        case .awaitingExport:     return .stageCaptionsReviewed
        case .stage(let s):
            switch s {
            case .created:          return .stageCreated
            case .programUploaded:  return .stageProgramUploaded
            case .ocrDone:          return .stageOCRDone
            case .photosAssigned:   return .stagePhotosAssigned
            case .assetsGenerated:  return .stageAssetsGenerated
            case .captionsReviewed: return .stageCaptionsReviewed
            case .exported:         return .stageExported
            }
        }
    }

    private var tooltipText: String {
        switch state {
        case .reading:            return "Reading the program in the background. You can keep working on other events."
        case .readingFailed:      return "Program OCR hit an error. Open this event to retry."
        case .generating:         return "Generating content in the background. You can keep working on other events."
        case .generationFailed:   return "Generation hit an error. Open this event to see what happened and retry."
        case .exporting:          return "Exporting in the background. You can keep working on other events."
        case .finishingMedia:     return "The folder is ready and the captions are in it. Reels and images are still being written."
        case .awaitingGeneration: return "Step 4: Photos assigned. Click Generate All to create assets."
        case .awaitingExport:     return "Step 6: Captions approved. Choose a folder and export."
        case .stage(let s):
            switch s {
            case .created:          return "Step 1: Event created. Upload the program PDF to begin."
            case .programUploaded:  return "Step 2: Program uploaded. Ready to run OCR."
            case .ocrDone:          return "Step 3: OCR complete. Review extracted text, then assign photos."
            case .photosAssigned:   return "Step 4: Photos assigned to posting days. Ready to generate assets."
            case .assetsGenerated:  return "Step 5: Assets generated. Review captions before exporting."
            case .captionsReviewed: return "Step 6: Reviewing captions. Approve to export."
            case .exported:         return "Step 7: Exported. All assets are in the output folder."
            }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if state.isBusy {
                Circle()
                    .fill(pillColor)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 0.35 : 1)
            }
            Text(state.label)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isSelected ? Color.primary.opacity(0.15) : pillColor.opacity(0.14))
        .foregroundStyle(isSelected ? Color.primary : pillColor)
        .clipShape(Capsule())
        .help(tooltipText)
        // Announce as "Stage, Photos Assigned" — not the "3 ·" prefix
        .accessibilityLabel("Stage")
        .accessibilityValue(state.label)
        .onChange(of: state.isBusy) { _, busy in
            pulse = false
            if busy { startPulse() }
        }
        .onAppear { if state.isBusy { startPulse() } }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
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
            Image(systemName: "music.mic")
                .font(.system(size: 28))
                .foregroundStyle(Color.warmMid.opacity(Opacity.subtle))
                .padding(.bottom, 4)
            Text("No events")
                .font(.light(12))
                .foregroundStyle(Color.warmMid)
            Text("Click New Event or press ⌘N to start.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.creamDeep)
    }
}
