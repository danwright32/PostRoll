import SwiftUI

struct OCRReviewView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    /// Owns the programme notes search, so it survives this section being
    /// collapsed and this screen being replaced (#693).
    @Environment(ProgramNotesManager.self) private var notesManager
    /// Owns the two performer lookups, so neither dies with the section that
    /// started it or with this screen (#707).
    @Environment(PerformerLookupManager.self) private var lookupManager
    /// For the rescan of pages an earlier run could not read (#518).
    @Environment(OCRManager.self) private var ocrManager
    /// Owns the "describe the correction" reflow, so a paid model call is not
    /// thrown away by an event switch (#718). This one LOST work rather than
    /// merely failing to report it: the corrected result was handed back into
    /// the draft below, which is destroyed with the screen.
    @Environment(OCRReflowManager.self) private var reflowManager
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

    /// Handles the book guessed from a name match, so the screen can mark them
    /// as guesses for as long as they are untouched (#459).
    @State private var bookSupplied: [UUID: String]

    init(event: Event) {
        self.event = event
        var ocrData = event.ocrResult ?? OCRResult()
        _bookSupplied = State(initialValue: HandleBook.shared.autoFill(
            performers: &ocrData.performers))
        _ocr = State(initialValue: ocrData)
        _orgHandles = State(initialValue: HandleBook.shared.handles(forOrg: event.org))
        _venueHandles = State(initialValue: HandleBook.shared.handles(forVenue: event.venue))
        _flags = State(initialValue: event.pendingFlags)
    }

    private var unresolvedFlags: [OCRFlag] { flags.filter { !$0.resolved } }

    /// Read the live event from AppState so a re-run that updates the error
    /// state reflects immediately. Falls back to the captured event.
    private var liveFlagsError: String? {
        (appState.events.first(where: { $0.id == event.id }) ?? event)
            .pendingFlagsError
    }

    /// Why the program's own text could not be used to check spelling (#209).
    /// Read live for the same reason as the flag error above.
    private var liveVisionSkipped: String? {
        (appState.events.first(where: { $0.id == event.id }) ?? event)
            .visionCheckSkipped
    }

    /// Why the event's website was not read for performers (#449). Read live
    /// for the same reason as the two above.
    private var liveWebPerformersSkipped: String? {
        (appState.events.first(where: { $0.id == event.id }) ?? event)
            .webPerformersSkipped
    }

    /// Programs taken knowingly incomplete (#378). Read live, and sorted so the
    /// same event reads the same way twice rather than in dictionary order.
    private var livePartialPrograms: [String] {
        (appState.events.first(where: { $0.id == event.id }) ?? event)
            .partialProgramNotes
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    /// The offer to read just the pages the earlier scan could not (#518), or
    /// nil when there is no gap.
    ///
    /// Read live for the same reason the notices are: the rescan writes back to
    /// the event, and a copy captured at init would keep offering to read pages
    /// that have just been read.
    private var rescanOffer: OCRReviewNotices.RescanOffer? {
        let live = appState.events.first(where: { $0.id == event.id }) ?? event
        guard let stored = live.ocrResult,
              let pages = OCRRescan.pages(for: stored,
                                          in: live.programImagePaths) else { return nil }
        // The same rule the run itself uses, so the control and what it does
        // cannot disagree about which pages are being read (L109). The count is
        // what will ACTUALLY be scanned, not the size of the gap, or the button
        // promises to read a page it is about to leave behind (#575).
        let plan = OCRRescan.plan(for: pages)
        guard !plan.sendable.isEmpty || plan.refusal != nil else { return nil }
        return OCRReviewNotices.RescanOffer(
            title: OCRRescan.buttonTitle(pageCount: plan.sendable.count),
            refusal: plan.refusal,
            note: plan.note,
            isRunning: ocrManager.isRunning(event.id),
            action: {
                ocrManager.startRescanOfUnreadPages(eventID: event.id,
                                                    appState: appState)
            }
        )
    }

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

                    // Every notice this screen can show, in its own view taking
                    // plain values, so the states that need a bad program to
                    // reach can be rendered and measured (#396).
                    OCRReviewNotices(
                        detectedIssues: detectedIssues,
                        partialProgramNotes: livePartialPrograms,
                        visionSkippedMessage: liveVisionSkipped.map {
                            OCRReviewReadiness.visionSkippedMessage($0)
                        },
                        webPerformersSkippedMessage: liveWebPerformersSkipped.map {
                            OCRReviewReadiness.webPerformersSkippedMessage($0)
                        },
                        flagErrorMessage: liveFlagsError.map {
                            OCRReviewReadiness.flagErrorMessage($0)
                        },
                        rescan: rescanOffer
                    )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)

                    if !flags.isEmpty {
                        FlagReviewSection(
                            flags: $flags,
                            isStringLeaf: { flag in
                                Self.pathIsStringLeaf(flag.fieldPath, in: ocr)
                            },
                            onApply: { flag, newValue in applyFlag(flag, newValue: newValue) },
                            onDismiss: { flag in dismissFlag(flag) },
                            eventID: event.id
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

                    OCRConfirmBar(
                        label: confirmButtonLabel,
                        help: confirmButtonHelp,
                        unresolvedFlagCount: unresolvedFlags.count,
                        onConfirm: { confirmAndAdvance() }
                    )
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
        .background(PaintedSurfaces.page)
        .animation(.easeOut(duration: 0.2), value: undoMessage != nil)
        // Draft persistence: all review edits live in @State, and the .id(event.id)
        // remount in EventDetailView discards that state the moment another event
        // is selected. Write every change through to the live event so corrections
        // survive event switches and app quits before "Looks Good".
        .onChange(of: ocr) { persistDraft() }
        .onChange(of: flags) { persistDraft() }
        // Take up what a rescan merged underneath this screen (#518).
        //
        // The draft above is written OUT on every edit, and the .id(event.id)
        // remount only reloads it when a different event is selected, so
        // nothing brought a change to the stored result back IN. The rescan is
        // the first thing that makes one while this screen is open: without
        // this the newly read pages were saved, the screen kept showing the
        // older list, and the next keystroke persisted that list back over the
        // merge and discarded them.
        .onChange(of: ocrManager.isRunning(event.id)) { adoptStoredResultIfNeeded() }
        // The notes search writes to the stored event the same way, and it very
        // often lands while this section is closed or after Dan has been to
        // another event and back (#693).
        .onChange(of: notesManager.isRunning(event.id)) { adoptStoredResultIfNeeded() }
        // The reflow writes to the stored event the same way, and it is the one
        // that most often lands after Dan has been to another event and back,
        // since it is a pair of model calls (#718).
        .onChange(of: reflowManager.isRunning(event.id)) { adoptStoredResultIfNeeded() }
        .onChange(of: orgHandles) {
            HandleBook.shared.record(org: event.org, handles: orgHandles)
        }
        .onChange(of: venueHandles) {
            HandleBook.shared.record(venue: event.venue, handles: venueHandles)
        }
    }

    /// Save in-progress review edits to the live event without advancing the
    /// stage or marking review done. confirmAndAdvance() remains the only
    /// place that finalizes the review.
    private func persistDraft() {
        guard var live = appState.events.first(where: { $0.id == event.id }),
              live.stage == .ocrDone else { return }
        // Never while a rescan is in flight. The draft on screen predates the
        // pages that run is reading, so persisting it now would write the older
        // list over a merge that is about to land, or has just landed (#518).
        guard !ocrManager.isRunning(event.id) else { return }
        // And never while the notes search is in flight, for the same reason
        // (#693): the draft on screen predates the notes that run is about to
        // write, so persisting it now would put the older list back over them.
        guard !notesManager.isRunning(event.id) else { return }
        // And never while a reflow is in flight, for the same reason again
        // (#718): it returns a whole replacement result, so persisting the
        // draft now would put the pre-correction list back over it.
        guard !reflowManager.isRunning(event.id) else { return }
        live.ocrResult = ocr
        live.pendingFlags = flags
        appState.updateEvent(live)
    }

    /// Bring a result written underneath this screen into the draft it shows.
    ///
    /// The decision is `OCRDraftRefresh`, so the rule and this call site cannot
    /// disagree about when it is safe (#518).
    private func adoptStoredResultIfNeeded() {
        let live = appState.events.first(where: { $0.id == event.id }) ?? event
        guard OCRDraftRefresh.shouldAdopt(
                stored: live.ocrResult, draft: ocr,
                isRunning: ocrManager.isRunning(event.id)
                    || notesManager.isRunning(event.id)
                    || reflowManager.isRunning(event.id))
        else { return }
        ocr = live.ocrResult ?? ocr
        flags = live.pendingFlags
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
        OCRReviewReadiness.detectedIssues(performerCount: ocr.performers.count,
                                          pieceCount: ocr.pieces.count)
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
                suppliedByBook: bookSupplied,
                // Read from the manager rather than held in the editor (#707):
                // this view is destroyed every time another section is opened,
                // and the progress, the clock, the error and the suggestions
                // all went with it.
                eventID: event.id,
                isLookingUpHandles: lookupManager.isRunning(.handles, for: event.id),
                handleLookupStartedAt: lookupManager.run(.handles, for: event.id)?.startedAt,
                handleLookupError: lookupManager.failure(.handles, for: event.id),
                handleSuggestions: lookupManager.suggestions(for: event.id),
                isFetchingFromWeb: lookupManager.isRunning(.fromWeb, for: event.id),
                fetchFromWebStartedAt: lookupManager.run(.fromWeb, for: event.id)?.startedAt,
                fetchError: lookupManager.failure(.fromWeb, for: event.id),
                onLookUpHandles: {
                    lookupManager.clearFailure(.handles, for: event.id)
                    lookupManager.startHandleLookup(
                        eventID: event.id, org: event.org, venue: event.venue,
                        eventName: event.name, appState: appState)
                },
                onFetchFromWeb: { url in
                    lookupManager.clearFailure(.fromWeb, for: event.id)
                    lookupManager.startWebFetch(
                        eventID: event.id, url: url, eventName: event.name,
                        appState: appState)
                },
                onAcceptSuggestion: { suggestion in
                    lookupManager.apply(suggestion, to: event.id, in: appState)
                },
                onDismissSuggestion: { suggestion in
                    lookupManager.dropSuggestion(named: suggestion.name, for: event.id)
                },
                onDismissAllSuggestions: {
                    lookupManager.dropAllSuggestions(for: event.id)
                },
                onDeleted: { performer, idx in
                    scheduleUndo(message: "Performer removed") {
                        ocr.performers.insert(performer, at: min(idx, ocr.performers.count))
                    }
                },
                // The list it replaced lives on the run, so the undo survives
                // this screen being torn down (#707, L97).
                onReplacedFromWeb: {
                    scheduleUndo(message: "Replaced from website") {
                        lookupManager.undoWebFetch(for: event.id, in: appState)
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
                eventName: event.name,
                // Read from the manager rather than held here (#693): this view
                // is destroyed every time another section is opened, and with
                // it went the indicator, the clock and the error message.
                isFetchingNotes: notesManager.isRunning(event.id),
                fetchStartedAt: notesManager.run(for: event.id)?.startedAt,
                fetchError: notesManager.failure(for: event.id),
                onFetchNotes: {
                    notesManager.clearFailure(for: event.id)
                    notesManager.start(eventID: event.id, org: event.org,
                                       eventName: event.name, appState: appState)
                }
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
        OCRReviewReadiness.confirmLabel(unresolvedFlagCount: unresolvedFlags.count,
                                        hasDetectedIssues: detectedIssues != nil)
    }

    private var confirmButtonHelp: String {
        OCRReviewReadiness.confirmHelp(unresolvedFlagCount: unresolvedFlags.count,
                                       hasDetectedIssues: detectedIssues != nil)
    }

    private func applyFlag(_ flag: OCRFlag, newValue: String) -> Bool {
        if applyValue(newValue, atPath: flag.fieldPath, to: &ocr) {
            markResolved(flag)
            return true
        }
        return false
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

    /// True when `path` lands on a leaf that can be overwritten with a plain string
    /// (i.e. it's a String/Int/etc, not an Array or Object). Used to decide whether
    /// the simple "Save correction" text-field path makes sense for a given flag.
    static func pathIsStringLeaf(_ path: [FlagPathSegment], in ocr: OCRResult) -> Bool {
        guard !path.isEmpty,
              let data = try? JSONEncoder().encode(ocr),
              let tree = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return false
        }
        var node: Any = tree
        for seg in path {
            switch seg {
            case .key(let k):
                guard let dict = node as? [String: Any], let next = dict[k] else { return false }
                node = next
            case .index(let i):
                guard let arr = node as? [Any], i >= 0, i < arr.count else { return false }
                node = arr[i]
            }
        }
        // Arrays and dicts are not string-replaceable; null is treated as missing.
        if node is [Any] || node is [String: Any] || node is NSNull { return false }
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

        var ev = appState.events.first(where: { $0.id == event.id }) ?? event

        // Now that the user has finalized the OCR, the program images are no
        // longer needed, but only once the searchable PDF that replaces them
        // is verified to exist. These scans are the only copies of the program
        // (the sites they come from block re-download), and deleting them on a
        // bake that had failed, or one still running, destroyed it outright
        // (#80). When the PDF isn't ready the scans stay and the bake is
        // re-run; that bake deletes them itself once it has succeeded.
        switch ProgramScanRetention.decide(for: ev) {
        case .deleteScans:
            ProgramImageCleanup.delete(urls: ev.programImagePaths)
            ev.programImagePaths = []
        case .nothingToDelete:
            break
        case .keepScans:
            ProgramPDFBakery.shared.bake(eventID: ev.id, appState: appState,
                                         deletingScansOnSuccess: true)
        }

        ev.ocrResult = ocr
        ev.ocrReviewDone = true
        ev.eventHandles = deduped.joined(separator: ", ")
        ev.pendingFlags = []
        ev.pendingFlagsError = nil
        ev.visionCheckSkipped = nil
        ev.stage = .photosAssigned
        appState.updateEvent(ev)
    }

    private func goBack() {
        // Return to the upload screen, as the button label promises. The
        // .programUploaded stage mounts OCRProgressView, which starts a fresh
        // paid OCR run on appear; the user can re-run OCR from the upload
        // screen once they've adjusted the pages.
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.stage = .created
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
                        .foregroundStyle(isExpanded ? PaintedSurfaces.pageAccentText : PaintedSurfaces.secondaryText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isExpanded ? PaintedSurfaces.iconAccent : PaintedSurfaces.secondaryText)
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
    /// Handles the handle book guessed from a name match, so a guess is not
    /// shown as something read off this programme (#459).
    var suppliedByBook: [UUID: String] = [:]
    /// Both lookups, as the manager that owns them sees them (#707). Passed in
    /// rather than held here, because this editor is destroyed every time
    /// another section of the accordion is opened, and every piece of run state
    /// went with it: a run still going, one that finished and one that failed
    /// all showed nothing at all.
    let eventID: Event.ID
    let isLookingUpHandles: Bool
    let handleLookupStartedAt: Date?
    let handleLookupError: String?
    let handleSuggestions: [PythonBridge.HandleSuggestion]
    let isFetchingFromWeb: Bool
    let fetchFromWebStartedAt: Date?
    let fetchError: String?
    let onLookUpHandles: () -> Void
    let onFetchFromWeb: (String) -> Void
    let onAcceptSuggestion: (PythonBridge.HandleSuggestion) -> Void
    let onDismissSuggestion: (PythonBridge.HandleSuggestion) -> Void
    let onDismissAllSuggestions: () -> Void
    let onDeleted: (Performer, Int) -> Void
    /// Called when a web fetch has replaced the list, so the screen can offer
    /// its undo. The list it replaced is kept by the manager rather than handed
    /// over here, because the undo has to outlive this view.
    var onReplacedFromWeb: (() -> Void)?
    @Environment(AppState.self) private var appState

    private var performersWithoutHandles: Bool {
        performers.contains { !$0.name.isEmpty && $0.handle.isEmpty }
    }

    private func performerBinding(id: UUID, fallback: Performer) -> Binding<Performer> {
        Binding(
            get: { performers.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let idx = performers.firstIndex(where: { $0.id == id }) {
                    performers[idx] = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach(performers) { performer in
                PerformerRow(performer: performerBinding(id: performer.id, fallback: performer),
                             suppliedByBook: suppliedByBook[performer.id]) {
                    if let idx = performers.firstIndex(where: { $0.id == performer.id }) {
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
                    onAccept: onAcceptSuggestion,
                    onDismiss: onDismissSuggestion,
                    onDismissAll: onDismissAllSuggestions
                )
            }

            Divider().padding(.vertical, 4)

            // Look up handles button
            if isLookingUpHandles {
                LongRunIndicator(label: "Searching for Instagram handles…",
                                 startedAt: handleLookupStartedAt,
                                 silenceThreshold: LongRunState.localWorkSilenceThreshold)
                    .padding(.top, 2)
            } else if performersWithoutHandles {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        onLookUpHandles()
                    } label: {
                        Label("Look up handles", systemImage: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                    }
                    .buttonStyle(.plain)

                    Text("Searches the web for Instagram accounts matching your performers. You'll verify each one before it's applied.")
                        .font(.light(10))
                        .foregroundStyle(PaintedSurfaces.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = handleLookupError {
                        Text(err)
                            .font(.light(10))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                    }
                }
            }

            if let url = eventURL {
                if isFetchingFromWeb {
                    LongRunIndicator(label: "Fetching from website…",
                                     startedAt: fetchFromWebStartedAt,
                                     silenceThreshold: LongRunState.localWorkSilenceThreshold)
                        .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            onFetchFromWeb(url)
                        } label: {
                            Label("Replace from website", systemImage: "globe")
                                .font(.system(size: 12))
                                .foregroundStyle(PaintedSurfaces.pageAccentText)
                        }
                        .buttonStyle(.plain)

                        Text("Replaces the performer list with conductors and named groups from the event page. Use for DCINY-style concerts where the website is more useful than the program.")
                            .font(.light(10))
                            .foregroundStyle(PaintedSurfaces.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        if let err = fetchError {
                            Text(err)
                                .font(.light(10))
                                .foregroundStyle(PaintedSurfaces.pageAccentText)
                        }
                    }
                }
            }
        }
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
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Spacer()
                Button("Dismiss all") { onDismissAll() }
                    .font(.system(size: 10))
                    .foregroundStyle(PaintedSurfaces.secondaryText)
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
        case "high":   return PaintedSurfaces.stateSuccessText
        case "medium": return PaintedSurfaces.stateWarningText
        default:       return PaintedSurfaces.quietMark
        }
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(suggestion.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                    Circle()
                        .fill(confidenceColor)
                        .frame(width: 6, height: 6)
                        .help(suggestion.confidence + " confidence" + (suggestion.note.map { ": \($0)" } ?? ""))
                }
                if let handle = suggestion.handle {
                    Text(handle)
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
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
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Open Instagram profile to verify")
            }

            Button { onAccept() } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(PaintedSurfaces.stateSuccessText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apply this handle")
            .help("Apply this handle")

            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(PaintedSurfaces.quietMark)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss this suggestion")
            .help("Dismiss this suggestion")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(PaintedSurfaces.suggestionRowFill)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct PerformerRow: View {
    @Binding var performer: Performer
    /// The handle the handle book guessed for this performer, if it did (#459).
    var suppliedByBook: String? = nil
    let onDelete: () -> Void

    /// Only while the field still holds what the book put there. Once Dan has
    /// typed over it, it is his answer rather than a guess.
    private var isGuessed: Bool {
        HandleBookMark.isFromTheBook(supplied: suppliedByBook, current: performer.handle)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                BrandField("Name", text: $performer.name)
                BrandField("Description (optional)", text: $performer.voiceOrInstrument)
                    .frame(maxWidth: 200)
                VStack(alignment: .leading, spacing: 2) {
                    BrandField("@handle", text: $performer.handle)
                    if isGuessed {
                        Label(HandleBookMark.note, systemImage: "questionmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .help(HandleBookMark.explanation)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
                    .foregroundStyle(performer.name.isEmpty ? PaintedSurfaces.quietMark : PaintedSurfaces.secondaryText)
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .disabled(performer.name.isEmpty)
            .accessibilityLabel("Search Instagram for this performer")
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
    /// The notes search, as the manager that owns it sees it (#693). Passed in
    /// rather than held here, because this view goes away whenever another
    /// section is opened and every piece of run state with it.
    let isFetchingNotes: Bool
    let fetchStartedAt: Date?
    let fetchError: String?
    let onFetchNotes: () -> Void
    let onDeleted: (Piece, Int) -> Void

    @State private var reorderTargetID: UUID?

    private var missingNotesCount: Int {
        pieces.filter { $0.notes.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private func pieceBinding(id: UUID, fallback: Piece) -> Binding<Piece> {
        Binding(
            get: { pieces.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let idx = pieces.firstIndex(where: { $0.id == id }) {
                    pieces[idx] = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach(pieces) { piece in
                let pieceID = piece.id
                PieceRow(piece: pieceBinding(id: pieceID, fallback: piece),
                         isReorderTarget: reorderTargetID == pieceID) {
                    if let idx = pieces.firstIndex(where: { $0.id == pieceID }) {
                        let snapshot = pieces[idx]
                        pieces.remove(at: idx)
                        onDeleted(snapshot, idx)
                    }
                }
                .draggable(pieceID.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let srcIDString = items.first,
                          let srcID = UUID(uuidString: srcIDString),
                          srcID != pieceID,
                          let srcIdx = pieces.firstIndex(where: { $0.id == srcID }),
                          let dstIdx = pieces.firstIndex(where: { $0.id == pieceID })
                    else { return false }
                    withAnimation(.easeOut(duration: 0.2)) {
                        pieces.move(
                            fromOffsets: IndexSet(integer: srcIdx),
                            toOffset: srcIdx < dstIdx ? dstIdx + 1 : dstIdx
                        )
                    }
                    return true
                } isTargeted: { targeted in
                    reorderTargetID = targeted ? pieceID : (reorderTargetID == pieceID ? nil : reorderTargetID)
                }
            }
            BrandAddButton(label: "Add Work") { pieces.append(Piece()) }

            if missingNotesCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if isFetchingNotes {
                        LongRunIndicator(label: "Searching the web…",
                                         startedAt: fetchStartedAt,
                                         silenceThreshold: LongRunState.localWorkSilenceThreshold)
                    } else {
                        Button {
                            onFetchNotes()
                        } label: {
                            Label(
                                "Fetch missing notes from web (\(missingNotesCount))",
                                systemImage: "globe"
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                        }
                        .buttonStyle(.plain)

                        Text("Asks Claude to find 1-2 sentence program notes for each work without notes. Skips pieces that already have notes.")
                            .font(.light(10))
                            .foregroundStyle(PaintedSurfaces.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let err = fetchError {
                        Text(err)
                            .font(.light(10))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.xs)
            }
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
                .foregroundStyle(PaintedSurfaces.tertiaryText)
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
                    .fill(PaintedSurfaces.dropTargetMarker)
                    .frame(height: 2)
                    .offset(y: -3)
            }
        }
    }
}

// MARK: - Scenes Editor

private struct ScenesEditor: View {
    @Binding var scenes: [ProgramScene]

    private func sceneBinding(id: UUID, fallback: ProgramScene) -> Binding<ProgramScene> {
        Binding(
            get: { scenes.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let idx = scenes.firstIndex(where: { $0.id == id }) {
                    scenes[idx] = newValue
                }
            }
        )
    }

    var body: some View {
        if scenes.isEmpty {
            Text("No scenes. Normal for concerts; scenes apply to operas and plays.")
                .font(.system(size: 12))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .padding(.bottom, Spacing.sm)
        } else {
            VStack(spacing: Spacing.sm) {
                ForEach(scenes) { scene in
                    let sceneID = scene.id
                    SceneRow(scene: sceneBinding(id: sceneID, fallback: scene)) {
                        scenes.removeAll { $0.id == sceneID }
                    }
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
            // Sponsor notes, dedications, audience instructions. Editable like
            // the rest because it reaches the blog prompt, and anything that
            // reaches the prompt has to be something Dan can correct (#262).
            BrandTextArea(label: "Other Program Text",  text: $ocr.other)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)

            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 12))
                .foregroundStyle(PaintedSurfaces.bodyText)
                .focusEffectDisabled()
                .frame(minHeight: 72)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(PaintedSurfaces.deepPage)
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
        .foregroundStyle(PaintedSurfaces.bodyText)
        .focusEffectDisabled()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(PaintedSurfaces.deepPage)
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
                .foregroundStyle(PaintedSurfaces.pageAccentText)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)
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
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // Only when there is an organisation to hold handles (#689). An
            // event can have none, and the row then showed a placeholder of a
            // bare "@" over a field whose value the handle book refuses to
            // store, because it is keyed by the organisation's name. A control
            // that cannot do anything is worse than an absent one: it invites
            // Dan to type something and then loses it (L109).
            if !orgName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HandleRow(
                    label: "Organization",
                    placeholder: "@\(orgName.lowercased().replacingOccurrences(of: " ", with: ""))",
                    text: $orgHandles
                )
            }
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
                .foregroundStyle(PaintedSurfaces.secondaryText)

            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundStyle(PaintedSurfaces.fieldPlaceholder)
            )
            .focused($focused)
            .font(.system(size: 12))
            .foregroundStyle(PaintedSurfaces.bodyText)
            .focusEffectDisabled()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(PaintedSurfaces.deepPage)
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
    let isStringLeaf: (OCRFlag) -> Bool
    let onApply: (OCRFlag, String) -> Bool
    let onDismiss: (OCRFlag) -> Void
    /// Which programme these concerns are about, so each row can find its own
    /// correction on the owner rather than being handed a closure that dies
    /// with this screen (#718).
    let eventID: Event.ID

    private var unresolvedCount: Int { flags.filter { !$0.resolved }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.iconAccent)
                Text(unresolvedCount > 0
                     ? "\(unresolvedCount) ISSUE\(unresolvedCount == 1 ? "" : "S") TO REVIEW"
                     : "ALL ISSUES RESOLVED")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
            }
            Text("Claude flagged these items as possibly wrong. Edit the value, keep the OCR text, or describe the correction in your own words.")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)

            VStack(spacing: Spacing.xs) {
                ForEach($flags) { $flag in
                    FlagRow(
                        flag: $flag,
                        isStringLeaf: isStringLeaf(flag),
                        onApply:   { newValue in onApply(flag, newValue) },
                        onDismiss: { onDismiss(flag) },
                        eventID: eventID
                    )
                }
            }
        }
        .padding(Spacing.md)
        .background(PaintedSurfaces.reflowPanelFill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(PaintedSurfaces.accentBorder.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct FlagRow: View {
    @Binding var flag: OCRFlag
    let isStringLeaf: Bool
    let onApply: (String) -> Bool
    let onDismiss: () -> Void
    let eventID: Event.ID

    @Environment(OCRReflowManager.self) private var reflowManager
    @Environment(AppState.self) private var appState

    @State private var draftValue: String = ""
    @State private var didInitDraft = false
    @State private var applyError: String? = nil

    // Reflow ("describe the correction"): only the composer is this row's
    // business. Whether a correction is running, what Claude replied and why
    // one failed all belong to the owner, because this row is destroyed
    // whenever the event changes and all three used to go with it (#718).
    @State private var reflowOpen: Bool = false
    @State private var reflowText: String = ""

    /// A correction running for THIS concern. Several rows are on screen, so a
    /// spinner on all of them would be a lie on all but one.
    private var isReflowing: Bool { reflowManager.isRunning(eventID, flag: flag.id) }
    private var reflowError: String? { reflowManager.failure(for: eventID, flag: flag.id) }
    private var reflowConfirmation: String? { reflowManager.reply(for: eventID, flag: flag.id) }
    /// A correction running for a DIFFERENT concern on this programme. The
    /// button is unavailable then, and says so.
    private var busyElsewhere: Bool { !reflowManager.canStart(eventID) && !isReflowing }

    private var pathLabel: String {
        flag.fieldPath.map(\.displayString).joined(separator: " · ")
    }

    /// Last `key` segment of the field path, e.g. "name" or "composer".
    /// Used in the "Replace [field] with:" label.
    private var fieldName: String {
        for seg in flag.fieldPath.reversed() {
            if case .key(let s) = seg { return s }
        }
        return "value"
    }

    /// True only when Claude actually proposed a different value (not when
    /// it just flagged the OCR text without a replacement).
    private var hasRealSuggestion: Bool {
        !flag.suggestedValue.isEmpty
            && flag.suggestedValue.trimmingCharacters(in: .whitespaces)
                != flag.currentValue.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedDraft: String {
        draftValue.trimmingCharacters(in: .whitespaces)
    }

    /// True when the user has changed the draft away from the current OCR value.
    /// Save is only enabled when there's an actual change to save.
    private var draftIsChange: Bool {
        !trimmedDraft.isEmpty && trimmedDraft != flag.currentValue.trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private var reflowSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let confirmation = reflowConfirmation {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(PaintedSurfaces.iconAccent)
                    Text(confirmation)
                        .font(.light(11))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } else if reflowOpen || isReflowing {
                Text("Describe the correction in your own words (e.g. \"Ordway is the arranger; composer is Traditional Chinese\"). Claude can update multiple fields at once.")
                    .font(.light(10))
                    .foregroundStyle(PaintedSurfaces.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                TextEditor(text: $reflowText)
                    .font(.system(size: 12))
                    .foregroundStyle(PaintedSurfaces.bodyText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 56, maxHeight: 120)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.xs)
                            .fill(PaintedSurfaces.page)
                            .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1))
                    )
                    .disabled(isReflowing)
                if let err = reflowError {
                    Text(err)
                        .font(.light(10))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if busyElsewhere {
                    Text(OCRReflowText.busyElsewhere)
                        .font(.light(10))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if isReflowing {
                        ProgressView().controlSize(.small)
                        Text("Asking Claude…")
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                    } else {
                        let nothingTyped = reflowText
                            .trimmingCharacters(in: .whitespaces).isEmpty
                        Button("Send to Claude") { startReflow() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(nothingTyped || busyElsewhere
                                             ? PaintedSurfaces.disabledControlLabel
                                             : PaintedSurfaces.pageAccentText)
                            .disabled(nothingTyped || busyElsewhere)
                        Button("Cancel") {
                            reflowOpen = false
                            reflowText = ""
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    }
                }
            } else {
                Button {
                    reflowOpen = true
                    // The last attempt's outcome lives on the owner now, so
                    // opening a fresh composer clears it there rather than in
                    // this row's own state.
                    reflowManager.clearOutcome(for: eventID)
                    if reflowText.trimmingCharacters(in: .whitespaces).isEmpty,
                       hasRealSuggestion {
                        reflowText = flag.suggestedValue
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                        Text("Describe the correction (let Claude rewrite)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Type a plain-English correction. Claude will update one or more fields on this item — useful when the right fix doesn't fit a single field.")
            }
        }
    }

    /// Hand the correction to the owner and let go of it.
    ///
    /// Nothing is awaited here on purpose. This row is destroyed whenever the
    /// event changes, and it used to be holding the only copy of the run's
    /// progress, its error and Claude's answer (#718).
    private func startReflow() {
        let msg = reflowText.trimmingCharacters(in: .whitespaces)
        guard !msg.isEmpty else { return }
        // The button is already unavailable in this case; refusing here as well
        // means a press that slips through cannot silently drop what Dan typed.
        guard reflowManager.canStart(eventID) else { return }
        // Forget the previous attempt, so its failure does not sit beside a run
        // that is going.
        reflowManager.clearOutcome(for: eventID)
        reflowManager.start(eventID: eventID, flag: flag.id,
                            userMessage: msg, appState: appState)
        // Kept, not cleared: the panel stays open showing the correction that
        // was sent while it runs, and Cancel is what throws it away.
        reflowOpen = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pathLabel.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                    Text(flag.concern)
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !flag.programContext.isEmpty {
                        Text(flag.programContext)
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if flag.resolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PaintedSurfaces.tertiaryText)
                        .labelStyle(.titleAndIcon)
                }
            }

            if !flag.resolved {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("OCR read:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(PaintedSurfaces.tertiaryText)
                        Text(flag.currentValue)
                            .font(.system(size: 10))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                            .strikethrough(hasRealSuggestion)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if hasRealSuggestion {
                        HStack(spacing: 4) {
                            Text("Claude suggests:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(PaintedSurfaces.pageAccentText)
                            Text(flag.suggestedValue)
                                .font(.system(size: 10))
                                .foregroundStyle(PaintedSurfaces.bodyText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else {
                        Text("Claude flagged this but didn't propose a replacement. Edit the value below if you can correct it, or click Keep OCR Text.")
                            .font(.light(10))
                            .foregroundStyle(PaintedSurfaces.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)

                if isStringLeaf {
                    Text("Replace \(fieldName) with:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                        .padding(.top, 4)

                    HStack(spacing: 6) {
                        TextField("", text: $draftValue)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(PaintedSurfaces.bodyText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.xs)
                                    .fill(PaintedSurfaces.page)
                                    .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                                        .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1))
                            )
                        Button("Save correction") {
                            guard draftIsChange else { return }
                            applyError = nil
                            if !onApply(trimmedDraft) {
                                applyError = "Couldn't apply that change here. Use Describe the correction below so Claude can patch the right spot."
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(draftIsChange ? PaintedSurfaces.pageAccentText
                                         : PaintedSurfaces.disabledControlLabel)
                        .disabled(!draftIsChange)
                        .help("Replace the \(fieldName) value with what you typed.")

                        Button("Keep OCR Text", action: onDismiss)
                            .help("The OCR text was correct. Mark this flag reviewed and leave the value alone.")
                            .buttonStyle(BrandOutlineButtonStyle())
                    }

                    if let err = applyError {
                        Text(err)
                            .font(.light(10))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("This fix changes the \(fieldName) list, so it can't be made in a single field. Use Describe the correction (Claude's suggestion is pre-filled) or Keep OCR Text.")
                        .font(.light(10))
                        .foregroundStyle(PaintedSurfaces.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)

                    HStack(spacing: 6) {
                        Button("Keep OCR Text", action: onDismiss)
                            .help("The OCR data was correct. Mark this flag reviewed and leave it alone.")
                            .buttonStyle(BrandOutlineButtonStyle())
                    }
                }

                reflowSection
            }
        }
        .padding(Spacing.sm)
        .background(flag.resolved ? PaintedSurfaces.resolvedFlagFill : PaintedSurfaces.page)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
        .opacity(flag.resolved ? 0.6 : 1.0)
        .onAppear {
            if !didInitDraft {
                // Pre-fill with Claude's proposed correction when there is one;
                // otherwise fall back to the OCR text so the user has something
                // to edit instead of an empty box.
                draftValue = hasRealSuggestion ? flag.suggestedValue : flag.currentValue
                didInitDraft = true
            }
        }
    }
}
