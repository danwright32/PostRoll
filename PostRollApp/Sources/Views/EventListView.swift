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
    /// Which row the pointer is over.
    ///
    /// On its own object, not on this view, because this view's body derives
    /// `filteredEvents`: a filter plus a search plus a sort over every Event,
    /// and an Event is a large value carrying its days, its photo paths and the
    /// whole week's generated result. Held here, every hover enter and leave
    /// invalidated that body and paid the whole derivation again, per row
    /// crossed by the mouse (#457, L59).
    ///
    /// Only `EventRowBackground` reads it, so a hover now re-renders the two
    /// rows whose backgrounds changed and nothing else.
    @State private var hover = EventListHover()
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
                        EventRowBackground(eventID: event.id,
                                           isSelected: isSelected,
                                           hover: hover,
                                           selectionNamespace: selectionNamespace)
                    )
                    .listRowInsets(EdgeInsets(top: Spacing.rowV, leading: Spacing.rowInset, bottom: Spacing.rowV, trailing: Spacing.rowInset))
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(PaintedSurfaces.edgeRule)
                    .contentShape(Rectangle())
                    // Writes the hover, never reads it, so this closure does
                    // not tie the list's body to the pointer (#457).
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) {
                            hover.eventID = hovering ? event.id : nil
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
        .background(PaintedSurfaces.deepPage)
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
                            .foregroundStyle(PaintedSurfaces.secondaryText)
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
                                    .foregroundStyle(showExported ? PaintedSurfaces.iconAccent : PaintedSurfaces.secondaryText)
                                    .frame(width: 18, height: 18)
                                if !showExported {
                                    Text("\(exportedCount)")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(PaintedSurfaces.exportedCountText)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 0.5)
                                        .background(Capsule().fill(PaintedSurfaces.exportedCountBadge))
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
                            .foregroundStyle(PaintedSurfaces.iconAccent)
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
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Text("Try clearing the search field.")
                        .font(.light(10))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Button("Clear Search") { searchText = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                        .padding(.top, Spacing.xs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PaintedSurfaces.deepPage)
            } else if filteredEvents.isEmpty && exportedCount > 0 {
                VStack(spacing: Spacing.sm) {
                    Text("All events are archived.")
                        .font(.light(12))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    Button("Show Archived") {
                        withAnimation(.easeOut(duration: 0.2)) { showExported = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PaintedSurfaces.deepPage)
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
        let trimmed = FieldText.normalized(renameText)
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

/// One row of the sidebar list.
///
/// Not private, so the legibility job can render the real row rather than a
/// stand-in built to look like it (#592). It is the screen Dan spends the most
/// time on and nothing had ever drawn one: #582 and #587 changed the colour of
/// every stage pill on it, and a ratio cannot see a label that is clipped,
/// behind its own capsule, or not rendering at all.
struct EventRow: View {
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
                    .foregroundStyle(PaintedSurfaces.bodyText)
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
                    // Warms towards the system label colour on selection, and
                    // stays the custom warm colour otherwise. Named rather
                    // than written here, so the pair walk can say what it
                    // measures: 11.61:1 selected, which is why this one moved
                    // nowhere while the lines below it did (#590).
                    .foregroundStyle(isSelected ? PaintedSurfaces.eventRowNameSelected
                                                : PaintedSurfaces.bodyText)
                    .lineLimit(1)
                    .padding(.bottom, 2)
            }

            HStack(spacing: 3) {
                Text(event.org)
                // Decoration between two facts, so it is taken out of the
                // accessibility tree rather than read out as "middle dot"
                // between every row's organisation and date (#538).
                Text("·").accessibilityHidden(true)
                Text(event.displayDate)
            }
            .font(.light(10))
            // Named rather than typed in, and deeper than the pair they were
            // (#590). `Color.secondary` put this line at 3.68:1 on a selected
            // row, and no check could say so: a system colour is outside the
            // palette, so no pair covered the one line that confirms the right
            // show was clicked.
            .foregroundStyle(isSelected ? PaintedSurfaces.eventRowDetailSelected
                                        : PaintedSurfaces.secondaryText)
            .lineLimit(1)

            HStack(spacing: 5) {
                Image(systemName: event.shootType.systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(event.shootType.rawValue)
                Spacer()
                // Resolved here, where the managers are, and drawn there. The
                // precedence between live work, a failure and the static stage
                // is a pure function with its own tests (#592).
                StagePill(state: StagePillState.resolve(
                              stage: event.stage,
                              isGenerating: genManager.isRunning(event.id),
                              generationFailed: genManager.hasFailed(event.id),
                              isReading: ocrManager.isRunning(event.id),
                              readingFailed: ocrManager.hasFailed(event.id),
                              isExporting: exportManager.isExporting(event.id),
                              isFinishingMedia: exportManager.isFinishingMedia(event.id),
                              awaitingGeneration: event.isAwaitingGeneration,
                              awaitingExport: event.isAwaitingExport),
                          isSelected: isSelected)
            }
            .font(.system(size: 10))
            .foregroundStyle(isSelected ? PaintedSurfaces.eventRowDetailSelected
                                        : PaintedSurfaces.secondaryText)
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

    /// What the pill announces, already resolved.
    ///
    /// The nine flags this used to take were resolved inside the view, so the
    /// only way to draw a given state was to work out which combination of
    /// flags produced it, and a test would have been holding a second copy of
    /// the precedence rule (L107). The rule is a pure function with its own
    /// tests; the row that has the managers calls it, and this draws the answer.
    /// That is what lets the legibility job render every state the pill can be
    /// in rather than the ones somebody could reconstruct (#592).
    let state: StagePillState
    var isSelected: Bool = false

    /// Subtle alive-signal pulse while any background work runs.
    @State private var pulse = false

    /// The wash behind the pill and the ink on it, from the one place that
    /// decides both (#582). The switch that used to live here returned a single
    /// colour drawn as the fill AND as the words on that fill, which is how
    /// every stage's label ended up between 2.42:1 and 3.67:1 against its own
    /// wash while the design note said they were calibrated as foreground.
    private var pill: (wash: Color, ink: Color) { PaintedSurfaces.stagePill(state) }

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
                    // The dot is drawn in the ink, not the wash: the two sit
                    // inside the same capsule, and the wash colour on its own
                    // wash is 3.01:1, which is the floor for a symbol with
                    // nothing to spare.
                    .fill(pill.ink)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 0.35 : 1)
            }
            Text(state.label)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isSelected ? PaintedSurfaces.selectedPillFill : pill.wash)
        .foregroundStyle(isSelected ? PaintedSurfaces.selectedPillLabel : pill.ink)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PaintedSurfaces.pageAccentText)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Spacing.sm)
        .background(PaintedSurfaces.deepPage)
        .overlay(Rectangle().fill(PaintedSurfaces.edgeRule).frame(height: 0.5), alignment: .top)
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
                    .foregroundStyle(PaintedSurfaces.bodyText)
                Spacer()
                Button("Done") { saveGlobal(); dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
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
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                        Text("Added to every caption automatically.")
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                        TextField("e.g. #dwphotony #nyc #concertphotography", text: $globalRaw)
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.bodyText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.xs)
                                    .fill(PaintedSurfaces.deepPage)
                                    .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                        .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1))
                            )
                            .onChange(of: globalRaw) { _, _ in saveGlobal() }
                    }

                    // Presets
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("PRESETS")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                        Text("Apply a saved group of hashtags to any caption with one tap.")
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)

                        ForEach(hashtagStore.presets) { preset in
                            HStack(alignment: .top, spacing: Spacing.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(PaintedSurfaces.bodyText)
                                    Text(preset.tags.joined(separator: " "))
                                        .font(.system(size: 10))
                                        .foregroundStyle(PaintedSurfaces.secondaryText)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button {
                                    hashtagStore.deletePreset(id: preset.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(PaintedSurfaces.secondaryText)
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                // Names WHAT it deletes, not just that it
                                // deletes: several of these sit in a row and
                                // "Delete" on each says nothing about which
                                // (#465, L20).
                                .accessibilityLabel("Delete the \(preset.name) hashtag preset")
                                .help("Delete the \(preset.name) hashtag preset")
                            }
                            .padding(.vertical, 4)
                            RoseGoldDivider(opacity: 0.3)
                        }

                        if showingAddPreset {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                TextField("Preset name (e.g. DCINY concert)", text: $newPresetName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(PaintedSurfaces.bodyText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.xs)
                                            .fill(PaintedSurfaces.deepPage)
                                            .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1))
                                    )
                                TextField("Tags (space-separated)", text: $newPresetTags)
                                    .font(.system(size: 12))
                                    .foregroundStyle(PaintedSurfaces.bodyText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.xs)
                                            .fill(PaintedSurfaces.deepPage)
                                            .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1))
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
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                                }
                            }
                            .padding(.top, Spacing.sm)
                        } else {
                            Button("Add preset…") { showingAddPreset = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(PaintedSurfaces.pageAccentText)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(Spacing.lg)
            }
        }
        .frame(width: 440)
        .background(PaintedSurfaces.page)
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
                .foregroundStyle(PaintedSurfaces.quietMark)
                .padding(.bottom, 4)
            Text("No events")
                .font(.light(12))
                .foregroundStyle(PaintedSurfaces.secondaryText)
            Text("Click New Event or press ⌘N to start.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaintedSurfaces.deepPage)
    }
}
