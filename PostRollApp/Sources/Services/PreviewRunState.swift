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
    /// The same, per day, so a single-day regen shows elapsed time too. It
    /// lived in the view as `regenerationStartTimes` and died on the
    /// `.id(event.id)` remount while the manager-owned spinner survived, which
    /// degraded the display to the indistinct state #135 exists to prevent
    /// (#456).
    private var dayRunStarts: [UUID: [DayName: Date]] = [:]
    /// Cover regeneration, kept apart from the day runs above on purpose:
    /// regenerating a cover must never look like, or trigger, a full reel or
    /// story regen (#141).
    private var coverRuns: [UUID: Set<DayName>] = [:]
    private var coverRunStarts: [UUID: [DayName: Date]] = [:]

    init() {}

    /// Registers a full preview run. Returns false when one is already in
    /// flight for this event, in which case the caller must not start another.
    mutating func beginFullRun(_ eventID: UUID, at now: Date = Date()) -> Bool {
        // A day already regenerating is writing media this run would write too
        // (#1009). The two claims used to consult only their own store, so both
        // said yes for one event and two `generate_media` subprocesses ran
        // against the same files. They also share one progress file, which is
        // per event and deleted by whichever starts second, the exact hazard
        // AppPaths.mediaProgressFile records. Refusing here removes the
        // collision rather than needing a second fix on the file.
        guard regeneratingDays(for: eventID).isEmpty else { return false }
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
    mutating func beginDay(_ day: DayName, for eventID: UUID, at now: Date = Date()) -> Bool {
        // The other half of the exclusion above (#1009). A full run already
        // writes every day's media, so a day run beside it is a second writer
        // on the same files and the same progress file.
        //
        // Refused BEFORE anything is recorded: a claim that returns false while
        // having inserted the day leaves a spinner running for work nobody
        // started, and the caller has no way to tell that from a real run.
        guard !isRunningFull(eventID) else { return false }
        var days = dayRuns[eventID] ?? []
        let inserted = days.insert(day).inserted
        dayRuns[eventID] = days
        if inserted { dayRunStarts[eventID, default: [:]][day] = now }
        return inserted
    }

    mutating func endDay(_ day: DayName, for eventID: UUID) {
        guard var days = dayRuns[eventID] else { return }
        days.remove(day)
        if days.isEmpty { dayRuns.removeValue(forKey: eventID) } else { dayRuns[eventID] = days }
        dayRunStarts[eventID]?.removeValue(forKey: day)
        if dayRunStarts[eventID]?.isEmpty == true { dayRunStarts.removeValue(forKey: eventID) }
    }

    func regeneratingDays(for eventID: UUID) -> Set<DayName> { dayRuns[eventID] ?? [] }

    /// When this day's regen started, or nil when it is not running.
    func dayStartedAt(_ day: DayName, for eventID: UUID) -> Date? {
        dayRunStarts[eventID]?[day]
    }

    // MARK: - Cover regeneration (#141)

    @discardableResult
    mutating func beginCover(_ day: DayName, for eventID: UUID, at now: Date = Date()) -> Bool {
        var days = coverRuns[eventID] ?? []
        let inserted = days.insert(day).inserted
        coverRuns[eventID] = days
        if inserted { coverRunStarts[eventID, default: [:]][day] = now }
        return inserted
    }

    mutating func endCover(_ day: DayName, for eventID: UUID) {
        guard var days = coverRuns[eventID] else { return }
        days.remove(day)
        if days.isEmpty { coverRuns.removeValue(forKey: eventID) } else { coverRuns[eventID] = days }
        coverRunStarts[eventID]?.removeValue(forKey: day)
        if coverRunStarts[eventID]?.isEmpty == true { coverRunStarts.removeValue(forKey: eventID) }
    }

    func coverRegeneratingDays(for eventID: UUID) -> Set<DayName> { coverRuns[eventID] ?? [] }

    func coverStartedAt(_ day: DayName, for eventID: UUID) -> Date? {
        coverRunStarts[eventID]?[day]
    }

    /// Any preview work at all for this event, full or per-day.
    func isBusy(_ eventID: UUID) -> Bool {
        isRunningFull(eventID) || !regeneratingDays(for: eventID).isEmpty
    }

    // MARK: - The image refresh counter (#1009)

    /// How many times each day's graphic has been rebuilt, per event.
    ///
    /// The number a rendered image is keyed on, so the view reloads the file
    /// instead of showing the copy it already decoded. It lived as `@State` on
    /// the caption review screen, written in six places there and read in one,
    /// which meant a redraw driven from any other screen finished successfully
    /// and left that screen showing the previous collage with nothing saying so.
    ///
    /// Keyed by event as well as day, which the view state could not be: it was
    /// keyed by day alone and thrown away on the remount that every event
    /// switch causes, so it could not answer the question at all once more than
    /// one screen could ask it.
    private var graphicVersions: [UUID: [DayName: Int]] = [:]

    func graphicVersion(_ day: DayName, for eventID: UUID) -> Int {
        graphicVersions[eventID]?[day] ?? 0
    }

    /// Records that this day's graphic has been redrawn.
    ///
    /// Monotonic per day rather than a flag: the reader compares the number it
    /// last drew against the number now, so two rebuilds have to be two
    /// different answers or the second one is invisible.
    mutating func bumpGraphicVersion(_ day: DayName, for eventID: UUID) {
        graphicVersions[eventID, default: [:]][day, default: 0] += 1
    }
}
