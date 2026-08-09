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
    /// When each run started, so the UI can show elapsed time and a stalled
    /// state rather than a spinner that looks the same whether the work is
    /// progressing, hung or dead (#95).
    private var fullRunStarts: [UUID: Date] = [:]

    init() {}

    /// Registers a full preview run. Returns false when one is already in
    /// flight for this event, in which case the caller must not start another.
    mutating func beginFullRun(_ eventID: UUID, at now: Date = Date()) -> Bool {
        guard fullRuns.insert(eventID).inserted else { return false }
        fullRunStarts[eventID] = now
        return true
    }

    mutating func endFullRun(_ eventID: UUID) {
        fullRuns.remove(eventID)
        fullRunStarts.removeValue(forKey: eventID)
    }

    /// When this event's full run started, or nil when none is in flight.
    func fullRunStartedAt(_ eventID: UUID) -> Date? { fullRunStarts[eventID] }

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
