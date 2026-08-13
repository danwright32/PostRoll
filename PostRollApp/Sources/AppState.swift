import Foundation
import Observation

enum SidebarMode: String { case events, insights }
enum InsightsSection: String { case overview, posts, orgs }

@MainActor
@Observable
final class AppState {
    var events: [Event] = []
    var selectedEventID: Event.ID?
    var showingNewEvent = false
    /// The list of days whose cached assets predate the current design (#293).
    var showingOutdatedDesigns = false

    /// Set at launch when the running app was built before the newest commit,
    /// so a fix that has already shipped may simply not be in this copy.
    ///
    /// Checked once per launch: it reads the disk and runs git, and the answer
    /// cannot change while the app is open.
    var buildBehind: BuildBehind?

    /// Set when events.json existed but its contents could not be decoded.
    /// Shown once as a dismissible alert; the bad file was moved aside, so
    /// starting from an empty list is safe.
    var dataLoadWarning: String?

    /// Set when events.json could not be read at all (a permission denial, an
    /// I/O error). The file is intact and untouched, its contents are unknown,
    /// and saving is refused, so the app must not let the user work in what
    /// looks like an empty library. Shown as a blocking alert with a retry.
    var storeUnavailable: String?

    /// Set the first time a save fails, and kept until one succeeds (#446).
    ///
    /// Not an alert: a failing disk fails every debounced keystroke, and a modal
    /// per keystroke is unusable. A banner that stays put is also the honest
    /// shape, because the condition persists until something changes.
    var saveFailure: String?

    /// An event that has been removed from the list but is still inside its
    /// undo window. Its media is deliberately still on disk.
    private(set) var pendingDeletion: Event?
    private var finalizeDeletionWork: DispatchWorkItem?

    // Analytics navigation
    var sidebarMode: SidebarMode = .events
    var insightsSection: InsightsSection = .overview

    /// Where the events store is read and written.
    ///
    /// A property rather than `EventStore.storeURL` at each call site, so the
    /// test seam below can point a whole AppState at a temp file and exercise the
    /// real save path, including its failures, without being able to reach the
    /// live events.json (L2).
    private let storeURL: URL

    #if POSTROLL_TESTS
    /// Test seam: an AppState holding exactly these events, with no read of the
    /// on-disk store and none of the launch sweeps. Tests must be structurally
    /// unable to see or rewrite the real events.json, and every sweep below
    /// deletes media based on which events exist.
    ///
    /// Compiled only into the test bundle. The shipping app cannot call this
    /// even by accident, and an accident here would not look like one: it would
    /// open showing an empty library while the real events sat on disk.
    init(events: [Event], storeURL: URL = EventStore.storeURL) {
        self.events = events
        self.storeURL = storeURL
    }
    #endif

    init() {
        storeURL = EventStore.storeURL
        // Data lives under AppPaths.root, which is ~/Library/Application Support
        // /PostRoll once the `.migrated` marker is present (the move was done
        // out-of-band, deliberately NOT on launch), otherwise the legacy
        // ~/Documents/PostRoll. No migration runs here.
        loadStore()
    }

    /// Reads the store and, only when what came back is the real event list,
    /// runs the launch sweeps. Every sweep below deletes files or rewrites the
    /// store based on which events exist, so running any of them against a list
    /// we failed to read would delete media for events that are still there.
    /// Also used by the retry button on the store-unavailable alert.
    func loadStore() {
        let loaded = EventStore.load(from: storeURL)
        events = loaded.events
        switch loaded.status {
        case .ok:
            dataLoadWarning = nil
            storeUnavailable = nil
        case .corrupt:
            dataLoadWarning = loaded.recoveryMessage
            storeUnavailable = nil
        case .unreadable:
            dataLoadWarning = nil
            storeUnavailable = loaded.recoveryMessage
        }

        guard loaded.isAuthoritative else { return }

        // Sweep: events past OCR review (photosAssigned and beyond) no longer
        // need their program images on disk — OCRReviewView.confirmAndAdvance
        // clears them when the user moves forward. We keep images alive
        // through .ocrDone so the user can press "Back" from OCR review and
        // re-run OCR on the same files (e.g. after re-launching the app).
        var dirty = false
        for i in events.indices where events[i].stage != .created
            && events[i].stage != .programUploaded
            && events[i].stage != .ocrDone
            && !events[i].programImagePaths.isEmpty {
            ProgramImageCleanup.delete(urls: events[i].programImagePaths)
            events[i].programImagePaths = []
            dirty = true
        }

        // Reclaim disk space from shoots archived more than ArchiveCleanup.archiveAgeDays ago.
        if ArchiveCleanup.sweep(events: &events, dataRoot: AppPaths.root) {
            dirty = true
        }

        // Copy any media still referenced from outside app storage (originals
        // picked from ~/Downloads/~/Desktop before the import-copy fix) into the
        // app's folder, so collage edits and exports stop re-triggering the
        // macOS permission prompt on every interaction.
        if MediaReclaim.reclaim(events: &events) {
            dirty = true
        }

        if dirty { persist() }

        // Reclaim photos/audio copies left behind by deleted events. Only
        // reachable on an authoritative load (guarded above): against an
        // empty or partial events array this would orphan, and delete, every
        // media file on disk.
        OrphanedMediaCleanup.sweep(events: events)

        // Same guard, same reason: the per-event progress files a deleted event
        // leaves behind. Housekeeping rather than space, so that the app has one
        // answer to who clears up per-event scratch files (#235).
        ProgressFileCleanup.sweep(events: events)
    }

    /// Every write of the store goes through here, so what happened to it cannot
    /// be reported by some edit paths and swallowed by others (#446).
    ///
    /// Six call sites wrote the store directly and all six discarded the outcome.
    /// `SaveCallSiteTests` holds this to one place, because fixing five of them
    /// would have left the sixth quietly losing work and nothing about reading
    /// any one of them would have shown which.
    @discardableResult
    private func persist() -> EventStore.SaveOutcome {
        let outcome = EventStore.save(events, to: storeURL)
        record(outcome)
        return outcome
    }

    /// Turn a save outcome into what the window shows.
    ///
    /// `blocked` deliberately raises nothing: it only happens when the store
    /// could not be READ, which already puts a blocking alert on screen with a
    /// retry, and a second notice would say the same thing twice.
    private func record(_ outcome: EventStore.SaveOutcome) {
        switch outcome {
        case .saved:
            saveFailure = nil
        case .blocked:
            break
        case .failed(let reason):
            saveFailure = SaveFailureNotice.message(reason: reason)
        }
    }

    /// Save again now, for the retry on the failure banner. Clears the banner if
    /// it works, and leaves it in place with a fresh reason if it does not.
    func retrySave() {
        storeWriter.flush()
        persist()
    }

    /// Coalesces per-keystroke saves. Owned here rather than by the review
    /// screen, which remounts whenever Dan switches events and would take a
    /// pending write down with it.
    ///
    /// `lazy` so the closure can report back: the whole point of #446 is that the
    /// debounced write was the one save whose outcome could reach nothing at all.
    /// The report runs inline when the write already happens on the main thread,
    /// which is every path except the writer's own deinit, so a flush and its
    /// banner land together rather than a frame apart.
    /// `@ObservationIgnored` because it is machinery rather than UI state, and
    /// because @Observable cannot generate tracking for a lazy property that
    /// captures self at all.
    @ObservationIgnored
    private lazy var storeWriter = DebouncedStoreWriter<[Event]> { [weak self, url = storeURL] events in
        let outcome = EventStore.save(events, to: url)
        if Thread.isMainThread {
            MainActor.assumeIsolated { self?.record(outcome) }
        } else {
            Task { @MainActor in self?.record(outcome) }
        }
    }

    func addEvent(_ event: Event) {
        events.append(event)
        selectedEventID = event.id
        persist()
    }

    func updateEvent(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        // Any pending text edit is written first, so an immediate structural
        // save can never land ahead of the typing that preceded it.
        storeWriter.flush()
        persist()
    }

    /// Same as `updateEvent`, but the DISK write is coalesced (#91, #197).
    ///
    /// For per-keystroke edits (caption, blog body, notes). The in-memory
    /// `events` array is updated immediately, exactly as `updateEvent` does, so
    /// every reader still sees the current text; only the serialisation of the
    /// whole store is deferred to a pause in typing. Typing a blog body used to
    /// cost hundreds of full store writes, scaling with how many events exist
    /// rather than with the size of the edit.
    func updateEventDebounced(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        storeWriter.schedule(events)
    }

    /// Write any pending text edit now.
    ///
    /// Every path that ends an editing session calls this: navigating away,
    /// generating, exporting, quitting. A debounce that loses the last sentence
    /// would be worse than the cost it saves.
    func flushPendingWrites() {
        storeWriter.flush()
    }

    /// Removes the event and starts its undo window. Its media stays on disk
    /// until the window closes, so Undo restores a working event rather than
    /// one whose photos were deleted a second earlier.
    func deleteEvent(id: Event.ID) {
        guard let event = events.first(where: { $0.id == id }) else { return }
        // Only one undo is ever offered, so an earlier pending delete is now
        // final and its media can go.
        finalizePendingDeletion()

        events.removeAll { $0.id == id }
        if selectedEventID == id { selectedEventID = nil }
        persist()
        pendingDeletion = event

        // Anything else the delete orphaned is reclaimed now; the event itself
        // still counts as an owner of its files until the window closes.
        OrphanedMediaCleanup.sweep(
            events: DeletionPolicy.mediaOwners(events: events, pendingDeletion: event)
        )

        let work = DispatchWorkItem { [weak self] in self?.finalizePendingDeletion() }
        finalizeDeletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DeletionPolicy.undoWindow, execute: work)
    }

    /// Puts back the event that is still inside its undo window, media intact.
    func undoDelete() {
        finalizeDeletionWork?.cancel()
        finalizeDeletionWork = nil
        guard let event = pendingDeletion else { return }
        pendingDeletion = nil
        addEvent(event)
    }

    /// Ends the undo window: the event is gone for good, so its media is
    /// reclaimed. Safe to call when nothing is pending. If the app quits first,
    /// the sweep at next launch reclaims the files instead.
    func finalizePendingDeletion() {
        finalizeDeletionWork?.cancel()
        finalizeDeletionWork = nil
        guard pendingDeletion != nil else { return }
        pendingDeletion = nil
        OrphanedMediaCleanup.sweep(events: events)
    }

    /// Duplicate an event: copies metadata and OCR result, clears photos and
    /// generated content, sets stage to the first step that needs fresh work.
    @discardableResult
    func duplicateEvent(id: Event.ID) -> Event.ID? {
        guard let original = events.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.days = [:]
        copy.blogPhotoPaths = []
        copy.weekResult = nil
        copy.exportPath = nil
        // Resume from the earliest stage that requires new input
        if original.ocrReviewDone {
            copy.stage = .photosAssigned
        } else if original.ocrResult != nil {
            copy.stage = .ocrDone
        } else if !original.programImagePaths.isEmpty {
            copy.stage = .programUploaded
        } else {
            copy.stage = .created
        }
        events.append(copy)
        selectedEventID = copy.id
        persist()
        return copy.id
    }
}
