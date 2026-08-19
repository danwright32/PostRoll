import Foundation
import Observation

/// Per-event bookkeeping shared by the background-work managers
/// ([GenerationManager], [OCRManager], [ExportManager]). Holds one in-flight or
/// just-finished job per event id and drives a single shared 1s elapsed ticker.
///
/// The `activeIDs` / `failedIDs` membership sets are deliberately separate
/// stored properties from `runs`: the sidebar reads the sets, which only change
/// on a start/finish transition, so the per-second tick that mutates `runs`
/// doesn't re-render every sidebar row. Managers *compose* this (has-a) rather
/// than subclass it — `@Observable` doesn't compose well with inheritance.
@MainActor
@Observable
final class EventJobTracker<Job> {

    private(set) var runs: [Event.ID: Job] = [:]
    private(set) var activeIDs: Set<Event.ID> = []
    private(set) var failedIDs: Set<Event.ID> = []

    /// Where the elapsed-seconds counter lives inside Job, so the shared ticker
    /// can advance it without knowing Job's shape.
    private let elapsed: WritableKeyPath<Job, Int>
    private var timer: Timer?

    init(elapsed: WritableKeyPath<Job, Int>) {
        self.elapsed = elapsed
    }

    // MARK: - Reads

    func job(for id: Event.ID) -> Job? { runs[id] }
    func isActive(_ id: Event.ID) -> Bool { activeIDs.contains(id) }

    /// Whether ANY event has work running, for the decisions that are about the
    /// app rather than about one event. Updating PostRoll is the first: it
    /// quits the app to install, so anything mid flight loses whatever it has
    /// not written back (#686).
    var hasWorkInFlight: Bool { !activeIDs.isEmpty }
    func hasFailed(_ id: Event.ID) -> Bool { failedIDs.contains(id) }

    // MARK: - Transitions

    /// Register a fresh job and mark it active; starts the ticker.
    func begin(_ job: Job, for id: Event.ID) {
        runs[id] = job
        activeIDs.insert(id)
        failedIDs.remove(id)
        ensureTimer()
    }

    /// Mutate an existing job in place (e.g. set a phase, status, or task handle).
    func update(_ id: Event.ID, _ mutate: (inout Job) -> Void) {
        guard var job = runs[id] else { return }
        mutate(&job)
        runs[id] = job
    }

    /// Stop counting an event as active but keep its job — for terminal state
    /// stored inside the job itself (e.g. export's `.done` phase).
    func deactivate(_ id: Event.ID) {
        activeIDs.remove(id)
        stopTimerIfIdle()
    }

    /// Mark a job failed: no longer active, flagged for the sidebar, job kept so
    /// its error message survives until acknowledged.
    func markFailed(_ id: Event.ID) {
        activeIDs.remove(id)
        failedIDs.insert(id)
        stopTimerIfIdle()
    }

    /// Remove a job entirely (success write-back done, or user cancelled).
    func remove(_ id: Event.ID) {
        runs.removeValue(forKey: id)
        activeIDs.remove(id)
        failedIDs.remove(id)
        stopTimerIfIdle()
    }

    /// Drop a terminal failed outcome once acknowledged — ignored while active.
    func clearFailed(_ id: Event.ID) {
        guard !isActive(id) else { return }
        runs.removeValue(forKey: id)
        failedIDs.remove(id)
    }

    // MARK: - Ticker

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        for id in activeIDs {
            if var job = runs[id] {
                job[keyPath: elapsed] += 1
                runs[id] = job
            }
        }
        stopTimerIfIdle()
    }

    private func stopTimerIfIdle() {
        if activeIDs.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
