import SwiftUI

struct OCRReviewView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @State private var ocr: OCRResult
    @State private var orgHandles: String
    @State private var venueHandles: String
    @State private var expanded: ReviewSection? = .performers
    @State private var flags: [OCRFlag]

    // Undo state
    @State private var undoMessage: String? = nil
    @State private var undoRestore: (() -> Void)? = nil
    @State private var undoWorkItem: DispatchWorkItem? = nil

    enum ReviewSection: String, CaseIterable {
        case performers = "Performers"
        case handles    = "Handles"
        case pieces     = "Program"
        case scenes     = "Scenes"
        case notes      = "Notes"
    }

    init(event: Event) {
        self.event = event
        var ocrData = event.ocrResult ?? OCRResult()
        HandleBook.shared.autoFill(performers: &ocrData.performers)
        _ocr = State(initialValue: ocrData)
        _orgHandles = State(initialValue: HandleBook.shared.handles(forOrg: event.org))
        _venueHandles = State(initialValue: HandleBook.shared.handles(forVenue: event.venue))
        _flags = State(initialValue: event.pendingFlags)
    }

    private var unresolvedFlags: [OCRFlag] { flags.filter { !$0.resolved } }

    var body: some View {
        ZStack(alignment: .bottom) {
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
                            message: issues.joined(separator: " "),
                            style: .error
                        )
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.md)
                    }

                    if !flags.isEmpty {
                        FlagReviewSection(
                            flags: $flags,
                            onApply: { flag, newValue in applyFlag(flag, newValue: newValue) },
                            onDismiss: { flag in dismissFlag(flag) }
                        )
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.md)
                    }

                    ForEach(ReviewSection.allCases, id: \.self) { section in
                        ReviewSectionRow(
                            title: sectionTitle(section),
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
                        Button(confirmButtonLabel) {
                            confirmAndAdvance()
                        }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(!unresolvedFlags.isEmpty)
                        .help(confirmButtonHelp)
                    }
                    .padding(Spacing.xl)
                }
            }

            if let message = undoMessage {
                OCRUndoBanner(message: message) {
                    undoRestore?()
                    dismissUndo()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.cream)
        .animation(.easeOut(duration: 0.2), value: undoMessage != nil)
    }

    // MARK: - Undo

    private func scheduleUndo(message: String, restore: @escaping () -> Void) {
        undoWorkItem?.cancel()
        undoMessage = message
        undoRestore = restore
        let work = DispatchWorkItem { dismissUndo() }
        undoWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func dismissUndo() {
        undoMessage = nil
        undoRestore = nil
        undoWorkItem = nil
    }

    // MARK: - Helpers

    private func sectionTitle(_ section: ReviewSection) -> String {
        switch section {
        case .performers:
            return ocr.performers.isEmpty ? "Performers (empty)" : "Performers (\(ocr.performers.count))"
        case .handles:
            let any = !orgHandles.isEmpty || !venueHandles.isEmpty
            return any ? "Handles (set)" : "Handles"
        case .pieces:
            return ocr.pieces.isEmpty ? "Program (empty)" : "Program (\(ocr.pieces.count))"
        case .scenes:
            return ocr.scenes.isEmpty ? "Scenes (none)" : "Scenes (\(ocr.scenes.count))"
        case .notes:
            return "Notes"
        }
    }

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
        case .performers:
            PerformersEditor(
                performers: $ocr.performers,
                eventURL: event.eventURL.isEmpty ? nil : event.eventURL,
                org: event.org,
                venue: event.venue,
                eventName: event.name,
                onDeleted: { performer, idx in
                    scheduleUndo(message: "Performer removed") {
                        ocr.performers.insert(performer, at: min(idx, ocr.performers.count))
                    }
                },
                onReplacedFromWeb: { old in
                    scheduleUndo(message: "Replaced from website") {
                        ocr.performers = old
                    }
                }
            )
        case .handles:
            EventHandlesField(
                orgHandles: $orgHandles,
                venueHandles: $venueHandles,
                orgName: event.org,
                venueName: event.venue
            )
        case .pieces:
            PiecesEditor(
                pieces: $ocr.pieces,
                org: event.org,
                eventName: event.name
            ) { piece, idx in
                scheduleUndo(message: "Work removed") {
                    ocr.pieces.insert(piece, at: min(idx, ocr.pieces.count))
                }
            }
        case .scenes:     ScenesEditor(scenes: $ocr.scenes)
        case .notes:      NotesEditor(ocr: $ocr)
        }
    }

    // MARK: - Flag handling

    private var confirmButtonLabel: String {
        if !unresolvedFlags.isEmpty {
            return "Resolve \(unresolvedFlags.count) issue\(unresolvedFlags.count == 1 ? "" : "s")"
        }
        return detectedIssues != nil ? "Continue Anyway" : "Looks Good"
    }

    private var confirmButtonHelp: String {
        if !unresolvedFlags.isEmpty {
            return "Apply or dismiss each flagged issue above before continuing."
        }
        return detectedIssues != nil
            ? "Missing data may produce generic captions. You can add performers or works now, or revise captions after generation."
            : ""
    }

    private func applyFlag(_ flag: OCRFlag, newValue: String) {
        if applyValue(newValue, atPath: flag.fieldPath, to: &ocr) {
            markResolved(flag)
        }
        // Apply failed silently (path drifted etc.) — leave unresolved so the user
        // can dismiss it once they've made the matching edit in the section editor.
    }

    private func dismissFlag(_ flag: OCRFlag) {
        markResolved(flag)
    }

    private func markResolved(_ flag: OCRFlag) {
        guard let idx = flags.firstIndex(where: { $0.id == flag.id }) else { return }
        flags[idx].resolved = true
    }

    /// Walk OCRResult as a JSON tree and overwrite the leaf at `path`.
    /// Returns false if the path doesn't resolve (stale index, missing key, etc.).
    private func applyValue(_ newValue: String, atPath path: [FlagPathSegment], to ocr: inout OCRResult) -> Bool {
        guard !path.isEmpty else { return false }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        guard let data = try? encoder.encode(ocr),
              var tree: Any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return false
        }
        guard Self.setStringValue(newValue, atPath: path, in: &tree) else { return false }
        guard let updated = try? JSONSerialization.data(withJSONObject: tree),
              let decoded = try? decoder.decode(OCRResult.self, from: updated) else {
            return false
        }
        ocr = decoded
        return true
    }

    private static func setStringValue(_ value: String, atPath path: [FlagPathSegment], in tree: inout Any) -> Bool {
        guard let head = path.first else { return false }
        let tail = Array(path.dropFirst())

        if tail.isEmpty {
            switch head {
            case .key(let k):
                guard var dict = tree as? [String: Any] else { return false }
                dict[k] = value
                tree = dict
                return true
            case .index(let i):
                guard var arr = tree as? [Any], i >= 0, i < arr.count else { return false }
                arr[i] = value
                tree = arr
                return true
            }
        }

        switch head {
        case .key(let k):
            guard var dict = tree as? [String: Any], var child = dict[k] else { return false }
            let ok = setStringValue(value, atPath: tail, in: &child)
            if ok { dict[k] = child; tree = dict }
            return ok
        case .index(let i):
            guard var arr = tree as? [Any], i >= 0, i < arr.count else { return false }
            var child = arr[i]
            let ok = setStringValue(value, atPath: tail, in: &child)
            if ok { arr[i] = child; tree = arr }
            return ok
        }
    }

    private func confirmAndAdvance() {
        // Save handles to HandleBook so future events at same org/venue auto-fill
        HandleBook.shared.record(org: event.org, handles: orgHandles)
        HandleBook.shared.record(venue: event.venue, handles: venueHandles)
        HandleBook.shared.recordAll(performers: ocr.performers)
        // Combine org + venue handles into the event-wide string (comma-separated, deduped)
        let combined = [orgHandles, venueHandles]
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        let deduped = Array(NSOrderedSet(array: combined)) as? [String] ?? combined

        // Now that the user has finalized the OCR, the program images are no
        // longer needed. (Cleanup is gated here, not at OCR completion, so the
        // flag-review step can re-read images if needed.)
        ProgramImageCleanup.delete(urls: event.programImagePaths)

        var ev = event
        ev.ocrResult = ocr
        ev.ocrReviewDone = true
        ev.eventHandles = deduped.joined(separator: ", ")
        ev.programImagePaths = []
        ev.pendingFlags = []
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
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { onToggle() }
            } label: {
                HStack(alignment: .center) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .transition(.opacity)
            }

            RoseGoldDivider(opacity: 0.3)
        }
    }
}

// MARK: - Performers Editor

private struct PerformersEditor: View {
    @Binding var performers: [Performer]
    var eventURL: String?
    var org: String = ""
    var venue: String = ""
    var eventName: String = ""
    let onDeleted: (Performer, Int) -> Void
    var onReplacedFromWeb: (([Performer]) -> Void)?

    @State private var isFetchingFromWeb = false
    @State private var fetchError: String?
    @State private var isLookingUpHandles = false
    @State private var handleSuggestions: [PythonBridge.HandleSuggestion] = []
    @State private var handleLookupError: String?
    @Environment(AppState.self) private var appState

    private var performersWithoutHandles: Bool {
        performers.contains { !$0.name.isEmpty && $0.handle.isEmpty }
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach($performers) { $p in
                PerformerRow(performer: $p) {
                    if let idx = performers.firstIndex(where: { $0.id == p.id }) {
                        let snapshot = performers[idx]
                        performers.remove(at: idx)
                        onDeleted(snapshot, idx)
                    }
                }
            }
            BrandAddButton(label: "Add Performer") {
                performers.append(Performer())
            }

            // Handle suggestions
            if !handleSuggestions.isEmpty {
                Divider().padding(.vertical, 4)
                HandleSuggestionsView(
                    suggestions: handleSuggestions,
                    onAccept: { suggestion in
                        applyHandleSuggestion(suggestion)
                    },
                    onDismiss: { suggestion in
                        handleSuggestions.removeAll { $0.name == suggestion.name }
                    },
                    onDismissAll: {
                        handleSuggestions = []
                    }
                )
            }

            Divider().padding(.vertical, 4)

            // Look up handles button
            if isLookingUpHandles {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(Color.roseGold)
                    Text("Searching for Instagram handles…")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                }
                .padding(.top, 2)
            } else if performersWithoutHandles {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        Task { await lookUpHandles() }
                    } label: {
                        Label("Look up handles", systemImage: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.roseGold)
                    }
                    .buttonStyle(.plain)

                    Text("Searches the web for Instagram accounts matching your performers. You'll verify each one before it's applied.")
                        .font(.light(10))
                        .foregroundStyle(Color.warmFaint)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = handleLookupError {
                        Text(err)
                            .font(.light(10))
                            .foregroundStyle(Color.roseDeep)
                    }
                }
            }

            if let url = eventURL {
                if isFetchingFromWeb {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(Color.roseGold)
                        Text("Fetching from website…")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                    .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            Task { await fetchFromWeb(url: url) }
                        } label: {
                            Label("Replace from website", systemImage: "globe")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.roseGold)
                        }
                        .buttonStyle(.plain)

                        Text("Replaces the performer list with conductors and named groups from the event page. Use for DCINY-style concerts where the website is more useful than the program.")
                            .font(.light(10))
                            .foregroundStyle(Color.warmFaint)
                            .fixedSize(horizontal: false, vertical: true)

                        if let err = fetchError {
                            Text(err)
                                .font(.light(10))
                                .foregroundStyle(Color.roseDeep)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func fetchFromWeb(url: String) async {
        fetchError = nil
        isFetchingFromWeb = true
        defer { isFetchingFromWeb = false }
        do {
            let fetched = try await PythonBridge.shared.fetchWebPerformers(eventURL: url)
            let old = performers
            performers = fetched
            onReplacedFromWeb?(old)
            NotificationService.shared.notifyWebPerformersFetched(
                eventName: eventName,
                count: fetched.count
            )
        } catch {
            fetchError = error.localizedDescription
        }
    }

    @MainActor
    private func lookUpHandles() async {
        handleLookupError = nil
        isLookingUpHandles = true
        defer { isLookingUpHandles = false }

        // First pass: fill from the handle book (instant, no web search)
        var bookFilled = 0
        for i in performers.indices {
            if performers[i].handle.isEmpty && !performers[i].name.isEmpty {
                let saved = HandleBook.shared.handle(forPerformer: performers[i].name)
                if !saved.isEmpty {
                    performers[i].handle = saved
                    bookFilled += 1
                }
            }
        }

        // Second pass: search the web for any still missing
        let needsLookup = performers.filter { !$0.name.isEmpty && $0.handle.isEmpty }
        guard !needsLookup.isEmpty else {
            // All handles resolved from the book — no web search needed
            NotificationService.shared.notifyHandleLookupComplete(
                eventName: eventName,
                count: bookFilled
            )
            return
        }

        do {
            let suggestions = try await PythonBridge.shared.suggestHandles(
                performers: needsLookup,
                org: org,
                venue: venue,
                event: eventName
            )
            // Only show suggestions that actually found something
            handleSuggestions = suggestions.filter { $0.handle != nil }
            NotificationService.shared.notifyHandleLookupComplete(
                eventName: eventName,
                count: handleSuggestions.count + bookFilled
            )
        } catch {
            handleLookupError = error.localizedDescription
        }
    }

    private func applyHandleSuggestion(_ suggestion: PythonBridge.HandleSuggestion) {
        guard let handle = suggestion.handle else { return }
        if let idx = performers.firstIndex(where: { $0.name == suggestion.name && $0.handle.isEmpty }) {
            performers[idx].handle = handle
        }
        handleSuggestions.removeAll { $0.name == suggestion.name }
    }
}

private struct HandleSuggestionsView: View {
    let suggestions: [PythonBridge.HandleSuggestion]
    let onAccept: (PythonBridge.HandleSuggestion) -> Void
    let onDismiss: (PythonBridge.HandleSuggestion) -> Void
    let onDismissAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HANDLE SUGGESTIONS")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color.warmMid)
                Spacer()
                Button("Dismiss all") { onDismissAll() }
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warmMid)
                    .buttonStyle(.plain)
            }

            ForEach(suggestions, id: \.name) { suggestion in
                HandleSuggestionRow(
                    suggestion: suggestion,
                    onAccept: { onAccept(suggestion) },
                    onDismiss: { onDismiss(suggestion) }
                )
            }
        }
    }
}

private struct HandleSuggestionRow: View {
    let suggestion: PythonBridge.HandleSuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    private var confidenceColor: Color {
        switch suggestion.confidence {
        case "high":   return Color.green.opacity(0.8)
        case "medium": return Color.orange.opacity(0.8)
        default:       return Color.warmMid.opacity(0.6)
        }
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(suggestion.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.warmDark)
                    Circle()
                        .fill(confidenceColor)
                        .frame(width: 6, height: 6)
                        .help(suggestion.confidence + " confidence" + (suggestion.note.map { ": \($0)" } ?? ""))
                }
                if let handle = suggestion.handle {
                    Text(handle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.roseGold)
                }
            }

            Spacer()

            // Verify link — opens Instagram profile
            if let urlString = suggestion.profileURL, let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Verify")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .buttonStyle(.plain)
                .help("Open Instagram profile to verify")
            }

            Button { onAccept() } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.green.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Apply this handle")

            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.warmMid.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Dismiss this suggestion")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.warmDark.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct PerformerRow: View {
    @Binding var performer: Performer
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                BrandField("Name", text: $performer.name)
                BrandField("Description (optional)", text: $performer.voiceOrInstrument)
                    .frame(maxWidth: 200)
                BrandField("@handle", text: $performer.handle)
                    .frame(maxWidth: 150)
            }
            Button {
                let parts = ["instagram", performer.name, performer.voiceOrInstrument]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let query = parts.joined(separator: " ")
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? parts.joined(separator: "+")
                if let url = URL(string: "https://www.google.com/search?q=\(query)") {
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
    let org: String
    let eventName: String
    let onDeleted: (Piece, Int) -> Void

    @State private var isFetchingNotes = false
    @State private var fetchError: String?
    @State private var reorderTargetID: UUID?

    private var missingNotesCount: Int {
        pieces.filter { $0.notes.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach($pieces) { $p in
                PieceRow(piece: $p, isReorderTarget: reorderTargetID == p.id) {
                    if let idx = pieces.firstIndex(where: { $0.id == p.id }) {
                        let snapshot = pieces[idx]
                        pieces.remove(at: idx)
                        onDeleted(snapshot, idx)
                    }
                }
                .draggable(p.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let srcIDString = items.first,
                          let srcID = UUID(uuidString: srcIDString),
                          srcID != p.id,
                          let srcIdx = pieces.firstIndex(where: { $0.id == srcID }),
                          let dstIdx = pieces.firstIndex(where: { $0.id == p.id })
                    else { return false }
                    withAnimation(.easeOut(duration: 0.2)) {
                        pieces.move(
                            fromOffsets: IndexSet(integer: srcIdx),
                            toOffset: srcIdx < dstIdx ? dstIdx + 1 : dstIdx
                        )
                    }
                    return true
                } isTargeted: { targeted in
                    reorderTargetID = targeted ? p.id : (reorderTargetID == p.id ? nil : reorderTargetID)
                }
            }
            BrandAddButton(label: "Add Work") { pieces.append(Piece()) }

            if missingNotesCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if isFetchingNotes {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(Color.roseGold)
                            Text("Searching the web…")
                                .font(.light(11))
                                .foregroundStyle(Color.warmMid)
                        }
                    } else {
                        Button {
                            Task { await fetchMissingNotes() }
                        } label: {
                            Label(
                                "Fetch missing notes from web (\(missingNotesCount))",
                                systemImage: "globe"
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(Color.roseGold)
                        }
                        .buttonStyle(.plain)

                        Text("Asks Claude to find 1-2 sentence program notes for each work without notes. Skips pieces that already have notes.")
                            .font(.light(10))
                            .foregroundStyle(Color.warmFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let err = fetchError {
                        Text(err)
                            .font(.light(10))
                            .foregroundStyle(Color.roseDeep)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.xs)
            }
        }
    }

    @MainActor
    private func fetchMissingNotes() async {
        fetchError = nil
        isFetchingNotes = true
        defer { isFetchingNotes = false }

        let missing = pieces.filter {
            $0.notes.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !missing.isEmpty else { return }

        do {
            let results = try await PythonBridge.shared.fetchPieceNotes(
                pieces: missing,
                org: org,
                event: eventName
            )
            // Match results back by content (title + composer) — order isn't
            // guaranteed and the live `pieces` may have been edited mid-fetch.
            for r in results {
                guard let note = r.notes?.trimmingCharacters(in: .whitespaces),
                      !note.isEmpty else { continue }
                let idx = pieces.firstIndex {
                    $0.title.caseInsensitiveCompare(r.title) == .orderedSame
                        && $0.composer.caseInsensitiveCompare(r.composer) == .orderedSame
                        && $0.notes.trimmingCharacters(in: .whitespaces).isEmpty
                }
                if let idx { pieces[idx].notes = note }
            }
        } catch {
            fetchError = error.localizedDescription
        }
    }
}

private struct PieceRow: View {
    @Binding var piece: Piece
    var isReorderTarget: Bool = false
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(Color.warmFaint)
                .padding(.top, 9)
                .help("Drag to reorder")
            VStack(spacing: 6) {
                HStack(spacing: Spacing.sm) {
                    BrandField("Title", text: $piece.title)
                    BrandField("Composer / Playwright / Artist", text: $piece.composer)
                }
                BrandField("Notes (optional)", text: $piece.notes, lineLimit: 3...10)
            }
            BrandDeleteButton(action: onDelete)
        }
        .padding(.vertical, 2)
        .overlay(alignment: .top) {
            if isReorderTarget {
                Rectangle()
                    .fill(Color.roseGold)
                    .frame(height: 2)
                    .offset(y: -3)
            }
        }
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
    let lineLimit: ClosedRange<Int>?
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, lineLimit: ClosedRange<Int>? = nil) {
        self.placeholder = placeholder
        _text = text
        self.lineLimit = lineLimit
    }

    var body: some View {
        Group {
            if let lineLimit {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(lineLimit)
            } else {
                TextField(placeholder, text: $text)
            }
        }
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

// MARK: - OCR Undo Banner

private struct OCRUndoBanner: View {
    let message: String
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

// MARK: - Event Handles Field

private struct EventHandlesField: View {
    @Binding var orgHandles: String
    @Binding var venueHandles: String
    let orgName: String
    let venueName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("These handles are added to every caption automatically.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)
                .fixedSize(horizontal: false, vertical: true)

            HandleRow(
                label: "Organization",
                placeholder: "@\(orgName.lowercased().replacingOccurrences(of: " ", with: ""))",
                text: $orgHandles
            )
            HandleRow(
                label: "Venue",
                placeholder: "@\(venueName.lowercased().replacingOccurrences(of: " ", with: ""))",
                text: $venueHandles
            )
        }
    }
}

private struct HandleRow: View {
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

            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundStyle(Color.warmMid.opacity(0.30))
            )
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

// MARK: - Flag Review Section

private struct FlagReviewSection: View {
    @Binding var flags: [OCRFlag]
    let onApply: (OCRFlag, String) -> Void
    let onDismiss: (OCRFlag) -> Void

    private var unresolvedCount: Int { flags.filter { !$0.resolved }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roseGold)
                Text(unresolvedCount > 0
                     ? "\(unresolvedCount) ISSUE\(unresolvedCount == 1 ? "" : "S") TO REVIEW"
                     : "ALL ISSUES RESOLVED")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.roseGold)
            }
            Text("Claude flagged these items as possibly wrong. Apply a correction or dismiss.")
                .font(.light(11))
                .foregroundStyle(Color.warmMid)

            VStack(spacing: Spacing.xs) {
                ForEach($flags) { $flag in
                    FlagRow(
                        flag: $flag,
                        onApply:   { newValue in onApply(flag, newValue) },
                        onDismiss: { onDismiss(flag) }
                    )
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.roseGold.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.roseGold.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct FlagRow: View {
    @Binding var flag: OCRFlag
    let onApply: (String) -> Void
    let onDismiss: () -> Void

    @State private var draftValue: String = ""
    @State private var didInitDraft = false

    private var pathLabel: String {
        flag.fieldPath.map(\.displayString).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pathLabel.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(Color.roseGold.opacity(0.7))
                    Text(flag.concern)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmDark)
                        .fixedSize(horizontal: false, vertical: true)
                    if !flag.programContext.isEmpty {
                        Text(flag.programContext)
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if flag.resolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmFaint)
                        .labelStyle(.titleAndIcon)
                }
            }

            if !flag.resolved {
                HStack(spacing: 6) {
                    TextField("Corrected value (or leave to dismiss)", text: $draftValue)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmDark)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.xs)
                                .fill(Color.cream)
                                .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                    .strokeBorder(Color.creamEdge, lineWidth: 1))
                        )
                    Button("Apply") {
                        let v = draftValue.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        onApply(v)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(draftValue.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color.warmFaint : Color.roseGold)
                    .disabled(draftValue.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmMid)
                }
            }
        }
        .padding(Spacing.sm)
        .background(Color.cream.opacity(flag.resolved ? 0.5 : 1.0))
        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
        .opacity(flag.resolved ? 0.6 : 1.0)
        .onAppear {
            if !didInitDraft {
                draftValue = flag.currentValue
                didInitDraft = true
            }
        }
    }
}
