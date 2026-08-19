import Foundation
import Observation

/// Owns the runs started from the caption review screen, so none of them dies
/// with it (#718).
///
/// Every one of them kept its in flight flag, its start time and its error in
/// `CaptionReviewView`'s own state, or in one of its rows'. `EventDetailView`
/// is `.id(event.id)` tagged, so an event switch remounts the whole screen and
/// destroys all three, and the screen that comes back shows the idle button.
///
/// The whole-week regeneration is the worst of them, and not only because it is
/// three to six minutes of paid Claude output. The two ways it can end EARLY, a
/// usage cap and a mid-run failure, both KEEP the days they finished and hand
/// back a banner saying which survived and where the two ways forward are
/// (#262). That banner lived in the view. Losing it does not merely leave Dan
/// uninformed: the days are on disk, the screen says nothing, and he re-runs
/// and pays again for work he already has.
///
/// The shape is `ProgramNotesManager`'s. What is different is that this screen
/// runs several DIFFERENT things on one event, so the key carries which, and a
/// caption revision going does not make the week regeneration read as busy.
@MainActor
@Observable
final class CaptionWorkManager {

    /// Which run this is. Part of the key rather than a manager each, because
    /// they are all runs on one week and must not be able to disagree about
    /// whether that week is busy.
    enum Job: Hashable {
        case regenerateWeek
    }

    private struct Key: Hashable {
        let eventID: Event.ID
        let job: Job
    }

    struct Run {
        var startedAt: Date
        var elapsedSeconds: Int
    }

    /// What a finished run left to say, kept after the run so that leaving the
    /// screen and coming back does not destroy it.
    struct Outcome: Equatable {
        /// Why it ended badly, OR the banner explaining what a run that stopped
        /// early managed to keep. The two are one field because they are one
        /// thing to the reader: something to act on before running again.
        var failure: String?
    }

    private let tracker = JobTracker<Key, Run>(elapsed: \.elapsedSeconds)
    private var outcomes: [Key: Outcome] = [:]

    // MARK: - Reads

    func isRunning(_ id: Event.ID, _ job: Job) -> Bool {
        tracker.isActive(Key(eventID: id, job: job))
    }

    func startedAt(_ id: Event.ID, _ job: Job) -> Date? {
        tracker.job(for: Key(eventID: id, job: job))?.startedAt
    }

    func outcome(for id: Event.ID, _ job: Job) -> Outcome? {
        outcomes[Key(eventID: id, job: job)]
    }

    /// Forget a finished run's outcome, so a retry starts clean.
    func clearOutcome(for id: Event.ID, _ job: Job) {
        outcomes[Key(eventID: id, job: job)] = nil
    }

    /// Whether anything here is going, for the decisions that are about the
    /// app. Updating quits to install (#686), and three to six paid minutes
    /// half way through is what must not be thrown away silently.
    var hasWorkInFlight: Bool { tracker.hasWorkInFlight }

    /// How long a run may take before it is called stalled.
    ///
    /// Outside the subprocess's own timeout rather than equal to it, and
    /// derived from it so the two cannot drift (L41). A whole week is the
    /// longest thing this app waits on, and the generator has its own watchdog;
    /// this is the backstop for a hang that is not the subprocess.
    static let deadline: TimeInterval = PythonBridge.processTimeout + 180

    #if POSTROLL_TESTS
    var deadlineForTesting: TimeInterval = CaptionWorkManager.deadline
    private var activeDeadline: TimeInterval { deadlineForTesting }
    #else
    private var activeDeadline: TimeInterval { Self.deadline }
    #endif

    #if POSTROLL_TESTS
    /// Test seam: the real one is minutes of paid Claude output (L2).
    var generateWeek: @Sendable (Event) async throws -> WeekGenerationResult = {
        try await PythonBridge.shared.runWeekGeneration(event: $0)
    }
    #else
    let generateWeek: @Sendable (Event) async throws -> WeekGenerationResult = {
        try await PythonBridge.shared.runWeekGeneration(event: $0)
    }
    #endif

    // MARK: - Regenerating the whole week

    func startRegeneratingWeek(eventID: Event.ID, appState: AppState,
                               globalHashtags: [String]) {
        let key = Key(eventID: eventID, job: .regenerateWeek)
        // Assume it runs twice. Coming back to the screen mid run showed the
        // idle button, so two whole-week runs on one event were one click away,
        // and both write the same week.
        guard !tracker.isActive(key) else { return }
        guard let live = appState.events.first(where: { $0.id == eventID }) else { return }

        outcomes[key] = nil
        tracker.begin(Run(startedAt: Date(), elapsedSeconds: 0), for: key)

        let generate = generateWeek
        let deadline = activeDeadline
        Task { @MainActor [weak self] in
            do {
                let week = try await DeadlinedWork.run(within: deadline) {
                    try await generate(live)
                }
                guard !Task.isCancelled else { return }
                self?.applyWholeWeek(week, to: eventID, in: appState,
                                     globalHashtags: globalHashtags)
                self?.finish(key, with: Outcome())
                NotificationService.shared.notifyRegenerationComplete(
                    eventName: live.name, what: "Captions")
            } catch let halt as WeekGenerationHalted {
                // The run stopped at a usage cap. What it finished is real and
                // paid for, so it is saved over the existing week rather than
                // discarded with the error (#262). The banner says which days
                // survived: a halt shown as a bare red error reads as a crash,
                // and Dan re-runs work he already has.
                let banner = HaltedWeek.from(halt.week)?.reviewBanner ?? halt.reason
                self?.keepPartial(halt.week, to: eventID, in: appState)
                self?.finish(key, with: Outcome(failure: banner))
            } catch let partial as WeekGenerationFailedWithPartial {
                // The run died with days already generated, usually the
                // watchdog. Saved for the same reason as a halt: they exist and
                // are paid for.
                self?.keepPartial(partial.week, to: eventID, in: appState)
                self?.finish(key, with: Outcome(
                    failure: partial.localizedDescription))
            } catch {
                self?.finish(key, with: Outcome(
                    failure: Self.failureMessage(error)))
            }
        }
    }

    // MARK: - Writing back

    /// Replace the week and fold in the global tags.
    ///
    /// The live event, re-read rather than the copy the run started from: this
    /// arrives minutes later and something else may have written in between.
    private func applyWholeWeek(_ week: WeekGenerationResult, to eventID: Event.ID,
                                in appState: AppState, globalHashtags: [String]) {
        guard var live = appState.events.first(where: { $0.id == eventID }) else { return }
        var next = week
        GlobalTagMerge.apply(globalHashtags, to: &next, for: live)
        live.weekResult = next
        appState.updateEvent(live)
    }

    /// Save what a run produced before it stopped.
    ///
    /// Through `PartialWeekMerge`, so a day the run never reached keeps the
    /// caption an earlier run produced instead of being overwritten with
    /// nothing (#262).
    private func keepPartial(_ week: WeekGenerationResult, to eventID: Event.ID,
                             in appState: AppState) {
        guard var live = appState.events.first(where: { $0.id == eventID }) else { return }
        live.weekResult = PartialWeekMerge.applying(week, onto: live.weekResult)
        appState.updateEvent(live)
    }

    private func finish(_ key: Key, with outcome: Outcome) {
        outcomes[key] = outcome
        tracker.remove(key)
    }

    /// What Dan reads when a run did not work.
    ///
    /// The stall gets its own sentence: "it failed" and "it never came back"
    /// are different problems with different next steps (L11).
    private static func failureMessage(_ error: Error) -> String {
        if let stalled = error as? DeadlinedWork.Stalled {
            return "The run did not come back within "
                 + "\(Int(stalled.seconds / 60)) minutes. Nothing was changed. "
                 + "Try again, and check the log if it happens twice."
        }
        return error.localizedDescription
    }
}
