import Foundation
import Observation

/// Owns the web search for missing programme notes, so it outlives the screen
/// that started it (#693).
///
/// The fetch used to be an unstructured `Task` started from `PiecesEditor`,
/// with its progress, its elapsed clock and its error message all in that
/// view's own `@State`. The review screen is an accordion: opening any other
/// section COLLAPSES Program, which takes `PiecesEditor` out of the view tree
/// and destroys all three. The run itself was not cancelled, so what Dan saw
/// was a search that had apparently died, with a run still alive, one that had
/// finished, and one that had failed all looking identical: the indicator was
/// simply gone. Reopening Program showed the idle button again, so a second
/// search could be stacked on the first.
///
/// Switching EVENTS is the worse case and the one that loses work rather than
/// merely reporting nothing. `EventDetailView` is `.id(event.id)` tagged, so
/// the whole screen remounts and the binding the results were written through
/// goes with it. The run then completes into nothing.
///
/// Both are the same defect: long running work belongs to an owner that
/// outlives the screen that started it (L17). `GenerationManager` was created
/// for exactly this shape when a generation died on an event switch, and it is
/// composed from `JobTracker`, which already holds one job per event and
/// drives the shared elapsed ticker. This reuses that rather than growing a
/// second mechanism beside it.
///
/// The results are written to the STORED event rather than through a binding,
/// the same way the targeted rescan writes, so they land whether or not any
/// screen is watching. The review screen takes them up through the rule #518
/// already established for that case.
@MainActor
@Observable
final class ProgramNotesManager {

    struct Run {
        var startedAt: Date
        var elapsedSeconds: Int
        /// Why it ended badly, kept after the run is over so the message is
        /// still there when the section is reopened. A failure that lived in the
        /// view died with it, which is how a failed search became silence.
        var failure: String?
        fileprivate var task: Task<Void, Never>?
    }

    private let tracker = JobTracker<Event.ID, Run>(elapsed: \.elapsedSeconds)


    /// Whether anything this owner started is still running (#862).

    ///

    /// The tracker has always known this; nothing forwarded it, so this

    /// owner was invisible to the one place that asked whether it was safe

    /// to quit or to install an update.

    var hasWorkInFlight: Bool { tracker.hasWorkInFlight }

    func run(for id: Event.ID) -> Run? { tracker.job(for: id) }
    func isRunning(_ id: Event.ID) -> Bool { tracker.isActive(id) }
    func failure(for id: Event.ID) -> String? { tracker.job(for: id)?.failure }

    /// Forget the last failure for this event, so a retry starts clean.
    ///
    /// Through the tracker's own acknowledgement, which refuses while a run is
    /// active: clearing a failure out from under a run that is going would take
    /// away a message about a different attempt.
    func clearFailure(for id: Event.ID) {
        tracker.clearFailed(id)
    }

    /// How long the search may take before it is called stalled.
    ///
    /// It is one model call over a handful of works. The deadline is well above
    /// that rather than close to it, for the reason every threshold in this app
    /// is: one that fires on ordinary runs trains Dan to ignore it (L36). What
    /// it buys is that a call which never returns becomes an error he can act
    /// on rather than an indicator that sits there forever (L110).
    static let deadline: TimeInterval = 300

    #if POSTROLL_TESTS
    /// Test seam: the deadline this manager actually uses.
    ///
    /// A test of the stall cannot wait five minutes, and one that waited a real
    /// five minutes would be a test nobody runs. Settable only in the test
    /// bundle, so the shipping app always uses the value above.
    var deadlineForTesting: TimeInterval = ProgramNotesManager.deadline
    private var activeDeadline: TimeInterval { deadlineForTesting }
    #else
    private var activeDeadline: TimeInterval { Self.deadline }
    #endif

    #if POSTROLL_TESTS
    /// Test seam: what the fetch actually is.
    ///
    /// The real one shells out to Python and calls a paid API. A suite able to
    /// reach that is a suite that spends money and needs a network (L2).
    var fetchNotes: @Sendable ([Piece], String, String) async throws -> [PythonBridge.PieceNoteResult] = {
        try await PythonBridge.shared.fetchPieceNotes(pieces: $0, org: $1, event: $2)
    }
    #else
    let fetchNotes: @Sendable ([Piece], String, String) async throws -> [PythonBridge.PieceNoteResult] = {
        try await PythonBridge.shared.fetchPieceNotes(pieces: $0, org: $1, event: $2)
    }
    #endif

    /// Start a search for the works on `eventID` that have no notes.
    ///
    /// Reads the pieces from the stored event rather than taking them as an
    /// argument, so what is searched for and what is written back are the same
    /// list, and a screen that has been torn down cannot hand over a stale one.
    func start(eventID: Event.ID, org: String, eventName: String,
               appState: AppState) {
        // Assume it runs twice. Reopening the section mid run showed the idle
        // button, so stacking two searches on one event was one click away.
        guard !tracker.isActive(eventID) else { return }

        let pieces = appState.events.first(where: { $0.id == eventID })?
            .ocrResult?.pieces ?? []
        let missing = pieces.filter { ProgramNotesMerge.needsNotes($0) }
        guard !missing.isEmpty else { return }

        tracker.begin(Run(startedAt: Date(), elapsedSeconds: 0, failure: nil),
                      for: eventID)

        let fetch = fetchNotes
        let deadline = activeDeadline
        let task = Task { @MainActor [weak self] in
            do {
                let results = try await DeadlinedWork.run(within: deadline) {
                    try await fetch(missing, org, eventName)
                }
                guard !Task.isCancelled else { return }
                self?.apply(results, to: eventID, in: appState)
                self?.tracker.remove(eventID)
            } catch is CancellationError {
                self?.tracker.remove(eventID)
            } catch {
                // Kept on the run rather than shown and forgotten: the section
                // it would appear in is very often closed by the time this
                // lands, and a reason that dies with the surface leaves Dan
                // pressing the same button with nothing to read (L148).
                self?.tracker.update(eventID) {
                    $0.failure = ProgramNotesMerge.failureMessage(error)
                }
                self?.tracker.markFailed(eventID)
            }
        }
        tracker.update(eventID) { $0.task = task }
    }

    /// Merge what came back into the event as it stands now.
    ///
    /// The live event, re-read rather than the copy the run started from: this
    /// arrives minutes later and the list may have been edited, so a note is
    /// only written where the work still exists and still has no notes.
    private func apply(_ results: [PythonBridge.PieceNoteResult],
                       to eventID: Event.ID, in appState: AppState) {
        guard var live = appState.events.first(where: { $0.id == eventID }),
              var stored = live.ocrResult else { return }
        guard ProgramNotesMerge.merge(results, into: &stored.pieces) else { return }
        live.ocrResult = stored
        appState.updateEvent(live)
    }
}

/// The decisions the notes search makes, apart from the running of it.
///
/// Pure, so each one can be stated and asserted without a process, a network or
/// a paid call behind it (L151).
enum ProgramNotesMerge {

    /// A work with nothing written about it yet.
    static func needsNotes(_ piece: Piece) -> Bool {
        piece.notes.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Write each result onto the work it is about, and say whether anything
    /// changed.
    ///
    /// Matched by title and composer rather than by position, because the order
    /// is not guaranteed and the list may have been edited while the search ran.
    /// Only onto works that still have no notes: a note Dan typed while waiting
    /// is his, and overwriting it would be the search destroying the work it
    /// was asked to save him.
    ///
    /// The Bool is the difference between a merge that did something and one
    /// that found nothing to do, so the caller can leave the stored event alone
    /// rather than writing an identical copy of it.
    @discardableResult
    static func merge(_ results: [PythonBridge.PieceNoteResult],
                      into pieces: inout [Piece]) -> Bool {
        var changed = false
        for result in results {
            guard let note = result.notes?.trimmingCharacters(in: .whitespaces),
                  !note.isEmpty else { continue }
            let index = pieces.firstIndex {
                $0.title.caseInsensitiveCompare(result.title) == .orderedSame
                    && $0.composer.caseInsensitiveCompare(result.composer) == .orderedSame
                    && needsNotes($0)
            }
            if let index {
                pieces[index].notes = note
                changed = true
            }
        }
        return changed
    }

    /// What Dan reads when the search did not work.
    ///
    /// The stall gets its own sentence, because "the search failed" and "the
    /// search never came back" are different problems with different next steps
    /// (L11).
    static func failureMessage(_ error: Error) -> String {
        if let stalled = error as? DeadlinedWork.Stalled {
            return "The web search did not come back within "
                 + "\(Int(stalled.seconds / 60)) minutes. Nothing was changed. "
                 + "Try again, or write the notes by hand."
        }
        return error.localizedDescription
    }
}

/// Asked whenever PostRoll is about to quit or install an update (#862).
///
/// The phrase is a clause rather than a name, because it is dropped into a
/// sentence that already says what is happening to it.
extension ProgramNotesManager: BackgroundWork {
    var workPhrase: String { "a programme notes search is still running" }
}
