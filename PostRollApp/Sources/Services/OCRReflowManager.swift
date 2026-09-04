import Foundation
import Observation

/// Owns the "describe the correction" reflow, so it outlives the row that
/// started it (#718, the third of the three #707 listed).
///
/// The reflow kept its in flight flag, its error and Claude's reply in
/// `FlagRow`'s own `@State`, and handed the corrected result back through a
/// closure into `OCRReviewView`'s draft. Both die with the screen, and the
/// review screen is `.id(event.id)` tagged, so switching events remounts the
/// lot. The paid model call then finished into nothing: unlike the other two
/// screens this LOST the correction rather than merely failing to report it,
/// and the row came back looking idle so a second could be stacked on the
/// first.
///
/// The shape is `ProgramNotesManager`'s, and the write is the one #518
/// established for this screen: the result goes to the STORED event, and the
/// draft on screen takes it up through `DraftRefresh`. That is what the
/// issue meant by the result landing somewhere different again: the review
/// screen holds a draft, so writing into that draft is writing into the view.
///
/// **One reflow at a time per event, and that is not tidiness.** Each run
/// returns a WHOLE replacement `OCRResult` computed from the state it started
/// with, so two running together means whichever lands second silently discards
/// the other's correction and the paid call that produced it (L5). The refusal
/// is scoped to the event because two events are two different results and
/// cannot overwrite each other.
@MainActor
@Observable
final class OCRReflowManager {

    struct Run {
        /// Which concern this correction is about.
        ///
        /// Several flags are on screen at once, so without this every row would
        /// show the spinner, and afterwards every row would show one answer.
        var flagID: OCRFlag.ID
        var startedAt: Date
        var elapsedSeconds: Int
        /// Claude's reply, kept after the run so it is still there when the row
        /// is rebuilt, which is what happens on every event switch.
        var reply: String?
        /// Why it ended badly, kept for the same reason. A failure that lived
        /// in the row died with it (L148).
        var failure: String?
        /// The handle on the work, so it can be stopped (#1050).
        ///
        /// It was started with a bare `Task { }` and the handle thrown away, so
        /// nothing could ever have stopped this: the screen put up a spinner
        /// and offered no way back. `JobTracker` requires this now, so a new
        /// owner cannot be written that way (L96).
        fileprivate var task: Task<Void, Never>?
    }

    private let tracker = JobTracker<Event.ID, Run>(elapsed: \.elapsedSeconds, task: \.task)

    // MARK: - Reads

    func run(for id: Event.ID) -> Run? { tracker.job(for: id) }
    func isRunning(_ id: Event.ID) -> Bool { tracker.isActive(id) }
    func startedAt(_ id: Event.ID) -> Date? { tracker.job(for: id)?.startedAt }

    /// Stop this run (#1050).
    ///
    /// Through the tracker, which is the one place stopping lives: it cancels
    /// the task, remembers the request so a screen can say it is winding down,
    /// and refuses a second press. Returns whether the request was taken, so a
    /// caller can tell a stop from a press that arrived after the work was
    /// already over (L197).
    ///
    /// This owner had no way to stop at all. It put up a spinner, and the only
    /// ways out of a run started by mistake were to wait or to quit the app.
    @discardableResult
    func stop(_ id: Event.ID) -> Bool { tracker.requestStop(id) }

    /// A stop was asked for and the work has not stopped yet.
    func isStopping(_ id: Event.ID) -> Bool { tracker.isStopping(id) }

    /// Whether the reflow going on this event is the one this row asked for.
    func isRunning(_ id: Event.ID, flag: OCRFlag.ID) -> Bool {
        isRunning(id) && tracker.job(for: id)?.flagID == flag
    }

    /// Claude's answer for one concern, or nil when the last run was about a
    /// different one. Scoped to the flag rather than to the event, so an answer
    /// is never shown against a concern it was not about.
    func reply(for id: Event.ID, flag: OCRFlag.ID) -> String? {
        guard let job = tracker.job(for: id), job.flagID == flag else { return nil }
        return job.reply
    }

    func failure(for id: Event.ID, flag: OCRFlag.ID) -> String? {
        guard let job = tracker.job(for: id), job.flagID == flag else { return nil }
        return job.failure
    }

    /// Forget the last outcome for this event so a retry starts clean.
    ///
    /// Through the tracker's own acknowledgement, which refuses while a run is
    /// active: clearing out from under a run that is going would take away a
    /// message about a different attempt.
    func clearOutcome(for id: Event.ID) {
        tracker.clearFailed(id)
    }

    var hasWorkInFlight: Bool { tracker.hasWorkInFlight }

    /// Whether a row on this event may send a correction now.
    ///
    /// The refusal inside `start` is the backstop; this is what the screen asks
    /// so it can DISABLE the button and say why, rather than swallowing the
    /// press and leaving Dan looking at a control that did nothing (L109, L148).
    func canStart(_ id: Event.ID) -> Bool { !isRunning(id) }

    /// How long a correction may take before it is called stalled.
    ///
    /// Outside the subprocess's own timeout rather than equal to it, and
    /// derived from that value so the two cannot drift (L41). It is two model
    /// calls, the review and then the patch apply, so this is the backstop for
    /// a hang that is not the subprocess.
    static let deadline: TimeInterval = PythonBridge.processTimeout + 180

    #if POSTROLL_TESTS
    /// Test seam: a test of the stall cannot wait half an hour.
    var deadlineForTesting: TimeInterval = OCRReflowManager.deadline
    private var activeDeadline: TimeInterval { deadlineForTesting }
    #else
    private var activeDeadline: TimeInterval { Self.deadline }
    #endif

    #if POSTROLL_TESTS
    /// Test seams. Both of these are paid model calls (L2).
    var review: @Sendable (OCRFlag, OCRResult, [URL], String) async throws
        -> PythonBridge.FlagReviewResponse = {
        try await PythonBridge.shared.reviewFlag(
            flag: $0, ocr: $1, imagePaths: $2, userMessage: $3)
    }
    var applyPatch: @Sendable ([PythonBridge.PatchOp], OCRFlag, OCRResult, [URL])
        async throws -> OCRResult = {
        try await PythonBridge.shared.applyFlagPatch(
            patch: $0, flag: $1, ocr: $2, imagePaths: $3)
    }
    #else
    let review: @Sendable (OCRFlag, OCRResult, [URL], String) async throws
        -> PythonBridge.FlagReviewResponse = {
        try await PythonBridge.shared.reviewFlag(
            flag: $0, ocr: $1, imagePaths: $2, userMessage: $3)
    }
    let applyPatch: @Sendable ([PythonBridge.PatchOp], OCRFlag, OCRResult, [URL])
        async throws -> OCRResult = {
        try await PythonBridge.shared.applyFlagPatch(
            patch: $0, flag: $1, ocr: $2, imagePaths: $3)
    }
    #endif

    // MARK: - Starting

    /// Ask Claude to apply `userMessage` to the concern `flag` on `eventID`.
    ///
    /// Reads the flag, the result and the page images off the STORED event
    /// rather than taking them as arguments, so what is corrected and what is
    /// written back are the same thing, and a row that has been torn down
    /// cannot hand over a stale copy.
    func start(eventID: Event.ID, flag flagID: OCRFlag.ID,
               userMessage: String, appState: AppState) {
        guard !tracker.isActive(eventID) else { return }
        guard let live = appState.events.first(where: { $0.id == eventID }),
              let concern = live.pendingFlags.first(where: { $0.id == flagID }),
              let ocr = live.ocrResult
        else { return }
        let images = live.programImagePaths

        tracker.begin(Run(flagID: flagID, startedAt: Date(), elapsedSeconds: 0,
                          reply: nil, failure: nil),
                      for: eventID)

        let ask = review
        let apply = applyPatch
        let deadline = activeDeadline
        let held = Task { @MainActor [weak self] in
            do {
                let response = try await DeadlinedWork.run(within: deadline) {
                    try await ask(concern, ocr, images, userMessage)
                }
                var corrected: OCRResult?
                if let patch = response.patch, !patch.isEmpty {
                    corrected = try await DeadlinedWork.run(within: deadline) {
                        try await apply(patch, concern, ocr, images)
                    }
                }
                guard !Task.isCancelled else {
                    // A stopped run ENDS rather than returning quietly (#1050).
                    // This used to return with the job still active, so the
                    // spinner ran for work that had stopped and nothing could
                    // clear it (L110). Reachable only now that there is a
                    // button that cancels.
                    self?.tracker.remove(eventID)
                    return
                }
                self?.write(corrected, resolving: response.resolved,
                            flag: flagID, to: eventID, in: appState)
                // The job is KEPT rather than removed: the reply is the whole
                // answer to what Dan asked, and it has to still be there when
                // the row is rebuilt. `deactivate` stops it counting as active
                // without throwing it away.
                self?.tracker.update(eventID) { $0.reply = response.assistantReply }
                self?.tracker.deactivate(eventID)
            } catch is CancellationError {
                self?.tracker.remove(eventID)
            } catch {
                self?.tracker.update(eventID) {
                    $0.failure = Self.failureMessage(error)
                }
                self?.tracker.markFailed(eventID)
                // Said out loud when he is not looking (#863).
                NotificationService.shared.notifyWorkFailed(
                    work: "applying the correction",
                    eventName: appState.events.first { $0.id == eventID }?.name ?? "An event",
                    reason: Self.failureMessage(error))
            }
        }
        // Held so the work can be stopped (#1050). It was a bare
        // `Task { }` and the handle went straight in the bin, so this
        // put up a spinner that nothing could ever have ended.
        tracker.update(eventID) { $0.task = held }
    }

    // MARK: - Writing back

    /// Put the correction on the event as it stands now.
    ///
    /// The live event, re-read rather than the copy the run started from: this
    /// arrives a paid call later. Nothing is written when there was no patch,
    /// so a reflow that only ANSWERED a question does not rewrite the result.
    private func write(_ corrected: OCRResult?, resolving resolved: Bool,
                       flag flagID: OCRFlag.ID, to eventID: Event.ID,
                       in appState: AppState) {
        guard var live = appState.events.first(where: { $0.id == eventID }) else { return }
        var changed = false

        if let corrected, corrected != live.ocrResult {
            live.ocrResult = corrected
            changed = true
        }
        // Only when Claude said the concern was answered. Tidying a flag away
        // that it did not resolve would take the question off the screen with
        // nothing having addressed it.
        if resolved,
           let index = live.pendingFlags.firstIndex(where: { $0.id == flagID }),
           !live.pendingFlags[index].resolved {
            live.pendingFlags[index].resolved = true
            changed = true
        }

        guard changed else { return }
        appState.updateEvent(live)
    }

    /// What Dan reads when the correction did not work.
    ///
    /// The stall gets its own sentence: "it failed" and "it never came back"
    /// are different problems with different next steps (L11).
    private static func failureMessage(_ error: Error) -> String {
        if let stalled = error as? DeadlinedWork.Stalled {
            return "Claude did not come back within "
                 + "\(Int(stalled.seconds / 60)) minutes. Nothing was changed. "
                 + "Try again, or correct the field by hand."
        }
        return error.localizedDescription
    }
}

/// The words the reflow rows have to show apart, apart from the running of it.
///
/// Pure, so each can be stated and asserted without a screen behind it (L151).
enum OCRReflowText {

    /// Why this row's button is unavailable: a different concern on the same
    /// programme is mid correction.
    ///
    /// Says what will happen rather than only what is wrong, because a message
    /// that names no next step leaves the person guessing (L111). Nothing is
    /// queued, so it does NOT promise this one will be sent automatically.
    static let busyElsewhere =
        "Another correction on this program is still being applied. "
        + "You can send this one as soon as that finishes."
}

/// Asked whenever PostRoll is about to quit or install an update (#862).
///
/// The phrase is a clause rather than a name, because it is dropped into a
/// sentence that already says what is happening to it.
extension OCRReflowManager: BackgroundWork {
    var workPhrase: String { "a correction is still being applied" }
}
