import Foundation
import Observation

/// # Work that outlives the screen that started it
///
/// The rule, written here because this is the mechanism every such run is built
/// on, and because a rule recorded only in an issue reaches nobody writing the
/// next one (#713, L27).
///
/// **A call that can take longer than a glance does not belong to a view.** Its
/// in flight flag, its start time, its error and its result belong to an owner
/// keyed by the event, and the view READS them rather than storing them.
///
/// Why, from three separate defects rather than from taste. A SwiftUI view is
/// destroyed whenever the thing showing it goes away, and two ordinary actions
/// do that here: the programme review screen is an accordion, so opening one
/// section destroys another, and every event detail screen is id tagged, so
/// switching events remounts the lot. When the run state lived in the view:
///
/// * the progress vanished, and a run still going, one that finished and one
///   that failed all looked identical, which is nothing at all (#693, #707);
/// * the error message vanished with it, so a failure that happened while the
///   section was closed could never be read (L148);
/// * the results were written through a binding into the destroyed view, so on
///   an event switch the work completed into nothing and was lost (#693);
/// * the button came back looking idle, so a second run could be stacked on the
///   first.
///
/// **The shape to copy** is `ProgramNotesManager` and `PerformerLookupManager`:
/// an `@Observable` owner holding one `Run` per event on this tracker, results
/// written to the STORED event rather than through a binding, a deadline so a
/// call that never returns becomes an error rather than an indicator that sits
/// there forever (L110), and a refusal to start twice.
///
/// `LongWorkOwnershipTests` fails the build when a view goes back to holding
/// this state itself, so the rule above is enforced rather than remembered.
///
/// Bookkeeping shared by the background-work managers. Holds one in-flight or
/// just-finished job per `Key` and drives a single shared 1s elapsed ticker.
///
/// `Key` is the thing the work is ABOUT. For most of these that is an event id,
/// because the run belongs to one event and switching events must not disturb
/// another's. Two runs are not about an event at all: the Insights CSV import
/// and the report generation, since there is one analytics history and one
/// report (#718). They key on their own small enum instead. The alternative was
/// a second mechanism beside this one for the work that has no event, and two
/// mechanisms for one rule is how the rule drifts.
///
/// The `activeIDs` / `failedIDs` membership sets are deliberately separate
/// stored properties from `runs`: the sidebar reads the sets, which only change
/// on a start/finish transition, so the per-second tick that mutates `runs`
/// doesn't re-render every sidebar row. Managers *compose* this (has-a) rather
/// than subclass it — `@Observable` doesn't compose well with inheritance.
@MainActor
@Observable
final class JobTracker<Key: Hashable, Job> {

    private(set) var runs: [Key: Job] = [:]
    private(set) var activeIDs: Set<Key> = []
    private(set) var failedIDs: Set<Key> = []

    /// Where the elapsed-seconds counter lives inside Job, so the shared ticker
    /// can advance it without knowing Job's shape.
    private let elapsed: WritableKeyPath<Job, Int>
    private var timer: Timer?

    init(elapsed: WritableKeyPath<Job, Int>) {
        self.elapsed = elapsed
    }

    // MARK: - Reads

    func job(for id: Key) -> Job? { runs[id] }
    func isActive(_ id: Key) -> Bool { activeIDs.contains(id) }

    /// Whether ANY event has work running, for the decisions that are about the
    /// app rather than about one event. Updating PostRoll is the first: it
    /// quits the app to install, so anything mid flight loses whatever it has
    /// not written back (#686).
    var hasWorkInFlight: Bool { !activeIDs.isEmpty }
    func hasFailed(_ id: Key) -> Bool { failedIDs.contains(id) }

    // MARK: - Transitions

    /// Register a fresh job and mark it active; starts the ticker.
    func begin(_ job: Job, for id: Key) {
        runs[id] = job
        activeIDs.insert(id)
        failedIDs.remove(id)
        ensureTimer()
        reportActivity()
    }

    /// Mutate an existing job in place (e.g. set a phase, status, or task handle).
    func update(_ id: Key, _ mutate: (inout Job) -> Void) {
        guard var job = runs[id] else { return }
        mutate(&job)
        runs[id] = job
    }

    /// Stop counting an event as active but keep its job — for terminal state
    /// stored inside the job itself (e.g. export's `.done` phase).
    func deactivate(_ id: Key) {
        activeIDs.remove(id)
        stopTimerIfIdle()
        reportActivity()
    }

    /// Mark a job failed: no longer active, flagged for the sidebar, job kept so
    /// its error message survives until acknowledged.
    func markFailed(_ id: Key) {
        activeIDs.remove(id)
        failedIDs.insert(id)
        stopTimerIfIdle()
        reportActivity()
    }

    /// Remove a job entirely (success write-back done, or user cancelled).
    func remove(_ id: Key) {
        runs.removeValue(forKey: id)
        activeIDs.remove(id)
        failedIDs.remove(id)
        stopTimerIfIdle()
        reportActivity()
    }

    /// Drop a terminal failed outcome once acknowledged — ignored while active.
    func clearFailed(_ id: Key) {
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
        reportActivity()
    }

    // MARK: - Telling the Dock (#863)

    /// Say whether this tracker has anything running, and for how long.
    ///
    /// Here rather than in each manager, because every manager composes this and
    /// these five transitions are already the complete set of moments when the
    /// answer can change. Wiring it per manager would be a list beside a list,
    /// and the one that fell behind would be the one whose work ran invisibly
    /// (L41, L96).
    ///
    /// Reported on the tick as well as on the transitions, so the Dock carries a
    /// number that keeps moving. A mark that never changes is the same picture
    /// whether the run is progressing, wedged or dead, which is the state this
    /// whole thing exists to end.
    ///
    /// The longest running job, because that is the one whose clock says the
    /// most about whether anything is still happening.
    private func reportActivity() {
        let longest = activeIDs.compactMap { runs[$0]?[keyPath: elapsed] }.max()
        NotificationService.shared.reportWork(self, runningFor: longest)
    }

    private func stopTimerIfIdle() {
        if activeIDs.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
