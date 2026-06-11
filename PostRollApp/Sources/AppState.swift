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

    /// Set when events.json existed but could not be decoded at launch.
    /// Shown once as an alert; the unreadable file was moved aside.
    var dataLoadWarning: String?

    // Analytics navigation
    var sidebarMode: SidebarMode = .events
    var insightsSection: InsightsSection = .overview

    init() {
        let loaded = EventStore.load()
        events = loaded.events
        dataLoadWarning = loaded.recoveryMessage
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
        if ArchiveCleanup.sweep(events: &events, projectRoot: AppPaths.root) {
            dirty = true
        }

        if dirty { EventStore.save(events) }
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
