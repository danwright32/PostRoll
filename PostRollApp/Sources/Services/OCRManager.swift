import Foundation
import Observation

/// Owns the OCR pipeline (program read → optional web performers → issue
/// flagging) at app scope, so a run survives the user switching events.
///
/// OCRProgressView previously drove the run with `.task(id:)`, which SwiftUI
/// cancels on view disappear — and the detail pane is `.id(event.id)`-tagged, so
/// switching events mid-OCR SIGTERM'd the Python process and threw away minutes
/// of work. Holding the task here, keyed by event id, lets OCR keep running
/// while the user works elsewhere. Mirrors [GenerationManager].
@MainActor
@Observable
final class OCRManager {

    struct Run {
        enum Status: Equatable {
            case running
            case failed(String)
        }
        var status: Status
        var elapsedSeconds: Int
        /// A late-stage label override (e.g. "Fetching performers from website…")
        /// the running screen shows in place of the elapsed-derived phase.
        var phaseOverride: String?
        fileprivate var task: Task<Void, Never>?
    }

    private let tracker = EventJobTracker<Run>(elapsed: \.elapsedSeconds)

    /// Why OCR would not run, per event, for the upload screen to show once it
    /// has been sent back there. Held here rather than on the event because it
    /// describes this attempt, not the record: it must not outlive the pages
    /// changing, and it has no business being written to disk.
    private var refusals: [Event.ID: String] = [:]

    func run(for id: Event.ID) -> Run? { tracker.job(for: id) }
    func isRunning(_ id: Event.ID) -> Bool { tracker.isActive(id) }
    func hasFailed(_ id: Event.ID) -> Bool { tracker.hasFailed(id) }

    /// Why the last attempt to run OCR was refused, or nil.
    func refusal(for id: Event.ID) -> String? { refusals[id] }

    /// Drops the refusal. Called when it is acknowledged, and whenever the
    /// pages it is about change, so a reason cannot go on being shown after it
    /// has stopped being true.
    func clearRefusal(for id: Event.ID) { refusals[id] = nil }

    /// Begin OCR for `eventID`. No-op if a run is already in flight for it, so
    /// re-entering the screen (or a view remount) doesn't launch a duplicate.
    func start(eventID: Event.ID, appState: AppState) {
        guard !isRunning(eventID) else { return }

        // The program has to be whole, and still on disk, before Python reads
        // it: OCR takes the pages it is given for the entire program, so a page
        // that is gone silently costs every performer and work printed on it
        // (#372). A refusal routes back to the upload screen carrying its own
        // reason, rather than bouncing Dan there with nothing said (#374).
        let live = appState.events.first(where: { $0.id == eventID })
        guard let ev = live else { return }
        let readiness = ProgramReadiness.of(ev.programImagePaths)
        guard readiness == .ready else {
            refusals[eventID] = readiness.refusal
            var back = ev
            back.stage = .created
            appState.updateEvent(back)
            return
        }

        refusals[eventID] = nil
        tracker.begin(Run(status: .running, elapsedSeconds: 0, phaseOverride: nil, task: nil), for: eventID)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runOCR(eventID: eventID, snapshot: ev, appState: appState)
        }
        tracker.update(eventID) { $0.task = task }
    }

    /// User cancelled. Removes the run; the caller handles navigation. Sending
    /// SIGTERM to Python happens via Swift task cancellation in PythonBridge.
    func cancel(eventID: Event.ID) {
        tracker.job(for: eventID)?.task?.cancel()
        tracker.remove(eventID)
    }

    /// Drop a failed outcome after the user acknowledges it (e.g. "Try Again").
    func clearOutcome(eventID: Event.ID) {
        tracker.clearFailed(eventID)
    }

    // MARK: - Pipeline

    private func runOCR(eventID: Event.ID, snapshot ev: Event, appState: AppState) async {
        let livePaths = (appState.events.first(where: { $0.id == eventID }) ?? ev).programImagePaths

        do {
            var result = try await PythonBridge.shared.runOCR(imagePaths: livePaths,
                                                              eventID: eventID)

            // DCINY events: the website lists conductors + group names (preferred
            // over the program, which lists every individual member).
            let url = ev.eventURL
            var webPerformersSkipped: String? = nil
            if !url.isEmpty, url.lowercased().contains("dciny.org") {
                tracker.update(eventID) { $0.phaseOverride = "Fetching performers from website…" }
                // Not `try?`. A network or script failure used to be
                // indistinguishable from the site listing nothing, and the run
                // shipped the program's list, which the comment above says is
                // the less preferred source, with nothing saying so (#449).
                // Same shape as visionSkipped five lines below, which records
                // its reason for exactly this reason.
                var fetched: [Performer]? = nil
                var failure: String? = nil
                do {
                    fetched = try await PythonBridge.shared.fetchWebPerformers(eventURL: url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failure = error.localizedDescription
                }
                switch WebPerformersOutcome.decide(fetched: fetched, failure: failure) {
                case .use(let performers):        result.performers = performers
                case .keepProgramList(let reason): webPerformersSkipped = reason
                }
            }

            TimingStore.shared.recordOCR(seconds: Double(tracker.job(for: eventID)?.elapsedSeconds ?? 0))

            // Second pass: ask Claude to flag suspicious OCR items. Non-blocking —
            // if it fails, the user can still review manually; capture the reason.
            tracker.update(eventID) { $0.phaseOverride = "Checking for issues…" }
            // The program PDF's Vision text layer is the spelling authority for
            // names and handles (#209). When it cannot be trusted the review
            // still runs, but the reason is recorded rather than swallowed: a
            // cross-check that silently did not happen looks exactly like a
            // program with nothing wrong in it.
            let live = appState.events.first(where: { $0.id == eventID }) ?? ev
            var visionText: String? = nil
            var visionSkipped: String? = nil
            switch VisionTextLayer.availability(for: live) {
            case .ready(let text):     visionText = text
            case .unavailable(let why): visionSkipped = why.explanation
            }

            var flags: [OCRFlag] = []
            var flagError: String? = nil
            do {
                flags = try await PythonBridge.shared.runFlagIssues(
                    ocr: result, imagePaths: livePaths, visionText: visionText)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                flagError = error.localizedDescription
            }

            finishSuccess(eventID: eventID, snapshot: ev, result: result,
                          flags: flags, flagError: flagError,
                          visionSkipped: visionSkipped,
                          webPerformersSkipped: webPerformersSkipped,
                          appState: appState)
        } catch is CancellationError {
            // User cancelled — cancel() already cleaned up state and navigation.
        } catch PythonBridgeError.partialOCR(let salvaged, let reason) {
            // The run died partway but had already read some of the programme,
            // and every page it read was a paid call (#479). Throwing that away
            // makes the retry pay for them again, so it is kept, and it is kept
            // WITH a note: a half-read cast list that looks complete is worse
            // than a failure, because nothing would tell Dan to check the rest.
            finishSuccess(
                eventID: eventID, snapshot: ev, result: salvaged,
                flags: [], flagError: nil, visionSkipped: nil,
                webPerformersSkipped: nil,
                appState: appState,
                partialRead: "Only part of the programme was read before the "
                    + "scan stopped. Check the cast list and notes against the "
                    + "printed programme, or scan again. (\(reason))")
        } catch {
            finishFailure(eventID: eventID, message: error.localizedDescription)
        }
    }

    /// Where a partial-read note is filed (#479).
    ///
    /// Deliberately not a file name: `ProgramShortfall.notes(clearedBy:)`
    /// removes a note whose key matches a re-imported programme, and this note
    /// is about the RUN rather than about any one upload. A complete read
    /// clears it instead, in `finishSuccess`, so it cannot outlive the fix.
    static let partialReadNoteKey = "This scan"


    private func finishSuccess(eventID: Event.ID, snapshot ev: Event, result: OCRResult,
                               flags: [OCRFlag], flagError: String?,
                               visionSkipped: String?, webPerformersSkipped: String?,
                               appState: AppState,
                               partialRead: String? = nil) {
        tracker.remove(eventID)

        // Base the write-back on the live event: OCR takes minutes and a snapshot
        // would revert edits (e.g. a rename) made during the run.
        var updated = appState.events.first(where: { $0.id == eventID }) ?? ev
        updated.ocrResult = result
        // This run's own note, set or cleared together. A complete read clears
        // what a partial one left, so a warning about pages that went unread
        // cannot outlive the run that finally read them. Independent of the
        // flag pass and the vision check, which have their own fields: one
        // status field shared by two checks lets a pass from one erase the
        // other's failure (L53).
        if let partialRead {
            updated.partialProgramNotes[Self.partialReadNoteKey] = partialRead
        } else {
            updated.partialProgramNotes.removeValue(forKey: Self.partialReadNoteKey)
        }
        updated.pendingFlags = flags
        updated.pendingFlagsError = flagError
        updated.visionCheckSkipped = visionSkipped
        updated.webPerformersSkipped = webPerformersSkipped
        updated.stage = .ocrDone
        appState.updateEvent(updated)
        NotificationService.shared.notifyOCRComplete(eventName: ev.name)
    }

    private func finishFailure(eventID: Event.ID, message: String) {
        guard tracker.job(for: eventID) != nil else { return }
        tracker.update(eventID) {
            $0.status = .failed(message)
            $0.task = nil
        }
        tracker.markFailed(eventID)
    }
}
