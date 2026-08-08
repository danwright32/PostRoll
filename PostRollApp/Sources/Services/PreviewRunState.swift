import Foundation
import Observation

/// What preview-graphics work is in flight, per event.
///
/// A value type so the rule that matters can be tested without an AppState or a
/// view: a second start for an event already running is refused. Preview
/// generation writes to fixed output paths, so two concurrent runs are two
/// writers on the same MP4s and PNGs (#75).
struct PreviewRunState: Equatable {
    private var fullRuns: Set<UUID> = []
    private var dayRuns: [UUID: Set<DayName>] = [:]

    init() {}

    /// Registers a full preview run. Returns false when one is already in
    /// flight for this event, in which case the caller must not start another.
    mutating func beginFullRun(_ eventID: UUID) -> Bool {
        fullRuns.insert(eventID).inserted
    }

    mutating func endFullRun(_ eventID: UUID) {
        fullRuns.remove(eventID)
    }

    func isRunningFull(_ eventID: UUID) -> Bool { fullRuns.contains(eventID) }

    /// Registers a single-day regeneration. Returns false when that day is
    /// already regenerating for this event.
    mutating func beginDay(_ day: DayName, for eventID: UUID) -> Bool {
        var days = dayRuns[eventID] ?? []
        let inserted = days.insert(day).inserted
        dayRuns[eventID] = days
        return inserted
    }

    mutating func endDay(_ day: DayName, for eventID: UUID) {
        guard var days = dayRuns[eventID] else { return }
        days.remove(day)
        if days.isEmpty { dayRuns.removeValue(forKey: eventID) } else { dayRuns[eventID] = days }
    }

    func regeneratingDays(for eventID: UUID) -> Set<DayName> { dayRuns[eventID] ?? [] }

    /// Any preview work at all for this event, full or per-day.
    func isBusy(_ eventID: UUID) -> Bool {
        isRunningFull(eventID) || !regeneratingDays(for: eventID).isEmpty
    }
}
