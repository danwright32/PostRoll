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
            var result = try await PythonBridge.shared.runOCR(imagePaths: livePaths)

            // DCINY events: the website lists conductors + group names (preferred
            // over the program, which lists every individual member).
            let url = ev.eventURL
            if !url.isEmpty, url.lowercased().contains("dciny.org") {
                tracker.update(eventID) { $0.phaseOverride = "Fetching performers from website…" }
                if let webPerformers = try? await PythonBridge.shared.fetchWebPerformers(eventURL: url),
                   !webPerformers.isEmpty {
                    result.performers = webPerformers
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
                          visionSkipped: visionSkipped, appState: appState)
        } catch is CancellationError {
            // User cancelled — cancel() already cleaned up state and navigation.
        } catch {
            finishFailure(eventID: eventID, message: error.localizedDescription)
        }
    }

    private func finishSuccess(eventID: Event.ID, snapshot ev: Event, result: OCRResult,
                               flags: [OCRFlag], flagError: String?,
                               visionSkipped: String?, appState: AppState) {
        tracker.remove(eventID)

        // Base the write-back on the live event: OCR takes minutes and a snapshot
        // would revert edits (e.g. a rename) made during the run.
        var updated = appState.events.first(where: { $0.id == eventID }) ?? ev
        updated.ocrResult = result
        updated.pendingFlags = flags
        updated.pendingFlagsError = flagError
        updated.visionCheckSkipped = visionSkipped
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
