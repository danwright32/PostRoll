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

    // Analytics navigation
    var sidebarMode: SidebarMode = .events
    var insightsSection: InsightsSection = .overview

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

    func addEvent(_ event: Event) {
        events.append(event)
        selectedEventID = event.id
        EventStore.save(events)
    }

    func updateEvent(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        EventStore.save(events)
    }

    func deleteEvent(id: Event.ID) {
        events.removeAll { $0.id == id }
        if selectedEventID == id { selectedEventID = nil }
        EventStore.save(events)
        // The deleted event's imported photos are now orphaned; reclaim any not
        // shared with a surviving event.
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
