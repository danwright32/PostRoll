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

    /// Set when events.json existed but its contents could not be decoded.
    /// Shown once as a dismissible alert; the bad file was moved aside, so
    /// starting from an empty list is safe.
    var dataLoadWarning: String?

    /// Set when events.json could not be read at all (a permission denial, an
    /// I/O error). The file is intact and untouched, its contents are unknown,
    /// and saving is refused, so the app must not let the user work in what
    /// looks like an empty library. Shown as a blocking alert with a retry.
    var storeUnavailable: String?

    /// An event that has been removed from the list but is still inside its
    /// undo window. Its media is deliberately still on disk.
    private(set) var pendingDeletion: Event?
    private var finalizeDeletionWork: DispatchWorkItem?

    // Analytics navigation
    var sidebarMode: SidebarMode = .events
    var insightsSection: InsightsSection = .overview

    #if POSTROLL_TESTS
    /// Test seam: an AppState holding exactly these events, with no read of the
    /// on-disk store and none of the launch sweeps. Tests must be structurally
    /// unable to see or rewrite the real events.json, and every sweep below
    /// deletes media based on which events exist.
    ///
    /// Compiled only into the test bundle. The shipping app cannot call this
    /// even by accident, and an accident here would not look like one: it would
    /// open showing an empty library while the real events sat on disk.
    init(events: [Event]) {
        self.events = events
    }
    #endif

    init() {
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
        let loaded = EventStore.load()
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

        if dirty { EventStore.save(events) }

        // Reclaim photos/audio copies left behind by deleted events. Only
        // reachable on an authoritative load (guarded above): against an
        // empty or partial events array this would orphan, and delete, every
        // media file on disk.
        OrphanedMediaCleanup.sweep(events: events)
    }

    /// Coalesces per-keystroke saves. Owned here rather than by the review
    /// screen, which remounts whenever Dan switches events and would take a
    /// pending write down with it.
    private let storeWriter = DebouncedStoreWriter<[Event]> { EventStore.save($0) }

    func addEvent(_ event: Event) {
        events.append(event)
        selectedEventID = event.id
        EventStore.save(events)
    }

    func updateEvent(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        // Any pending text edit is written first, so an immediate structural
        // save can never land ahead of the typing that preceded it.
        storeWriter.flush()
        EventStore.save(events)
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
        EventStore.save(events)
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
        EventStore.save(events)
        return copy.id
    }
}
