import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var events: [Event] = []
    var selectedEventID: Event.ID?
    var showingNewEvent = false

    init() {
        events = EventStore.load()
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
}
