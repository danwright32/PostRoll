import Foundation
import Observation

/// Owns in-flight content generation so a run survives the AssetGenerationView
/// being torn down.
///
/// AssetGenerationView lives inside EventDetailView, which is `.id(event.id)`
/// tagged: switching events in the sidebar remounts the detail pane. The
/// generation task used to live in that view's `@State` and was cancelled in
/// `onDisappear`, so kicking off "Generate All" and then clicking another event
/// killed the run. Holding the task here (app-scoped, keyed by event id) lets
/// the user start a generation, switch away to work on something else, and keep
/// the first event generating in the background.
@MainActor
@Observable
final class GenerationManager {

    struct Run {
        var status: AssetGenerationDisplay.RunStatus
        var elapsedSeconds: Int
        var retryDays: Set<String>?      // nil = full run
        fileprivate var task: Task<Void, Never>?
    }

    /// Active or just-failed generation per event. A successful run is removed
    /// once written back; the event's saved `weekResult` is then the source of
    /// truth for the "done" state.
    private let tracker = EventJobTracker<Run>(elapsed: \.elapsedSeconds)

    func run(for id: Event.ID) -> Run? { tracker.job(for: id) }

    func isRunning(_ id: Event.ID) -> Bool { tracker.isActive(id) }

    func hasFailed(_ id: Event.ID) -> Bool { tracker.hasFailed(id) }

    /// Begin (or restart) a generation for `eventID`. `retryDays` nil = full
    /// run; a set of day keys (and/or "blog") = partial retry merged into the
    /// existing weekResult.
    /// Begin a generation. `regenerateGraphics` overrides the default of
    /// graphics-only-on-full-run: pass `true` to also re-render previews for a
    /// partial retry (used when switching the posting preset, which changes the
    /// media for the affected days, not just their captions).
    func start(eventID: Event.ID, retryDays: Set<String>?, appState: AppState,
               regenerateGraphics: Bool? = nil) {
        // Snapshot the event for its input paths. The write-back later re-reads
        // the live event so edits made during the run aren't clobbered.
        guard let ev = appState.events.first(where: { $0.id == eventID }) else { return }

        tracker.job(for: eventID)?.task?.cancel()
        tracker.begin(Run(status: .running, elapsedSeconds: 0, retryDays: retryDays, task: nil), for: eventID)

        let onlyDays = retryDays
        // Graphics run in parallel with captions on a full run; retries skip
        // them unless explicitly requested (preset switch).
        let doGraphics = PreviewMergePolicy.shouldRenderGraphics(
            regenerateGraphics: regenerateGraphics, isFullRun: onlyDays == nil)
        let task = Task { [weak self] in
            let graphicsTask: Task<PythonBridge.PreviewGenerationResult?, Never>? = doGraphics
                ? Task { try? await PythonBridge.shared.runPreviewGeneration(event: ev, days: onlyDays.map { Array($0) }) }
                : nil

            do {
                let result = try await PythonBridge.shared.runWeekGeneration(event: ev, onlyDays: onlyDays)
                let mediaResult = await graphicsTask?.value
                self?.finishSuccess(eventID: eventID, snapshot: ev, onlyDays: onlyDays,
                                    result: result, mediaPaths: mediaResult?.paths,
                                    fridayClipPlan: mediaResult?.fridayClipPlan,
                                    coverPicks: mediaResult?.coverPicks ?? [:], appState: appState)
            } catch is CancellationError {
                graphicsTask?.cancel()
            } catch {
                graphicsTask?.cancel()
                self?.finishFailure(eventID: eventID, message: error.localizedDescription)
            }
        }
        tracker.update(eventID) { $0.task = task }
    }

    /// User-cancelled (Cancel button) or programmatic stop. Removes the run.
    func cancel(eventID: Event.ID) {
        tracker.job(for: eventID)?.task?.cancel()
        tracker.remove(eventID)
    }

    /// Drop a terminal (failed) outcome once the user has acknowledged it, so
    /// the view falls back to its configuring/done display.
    func clearOutcome(eventID: Event.ID) {
        tracker.clearFailed(eventID)
    }

    // MARK: - Completion

    private func finishSuccess(eventID: Event.ID, snapshot ev: Event, onlyDays: Set<String>?,
                               result: WeekGenerationResult, mediaPaths: [String: [String: String]]?,
                               fridayClipPlan: FridayClipPlan? = nil,
                               coverPicks: [String: CoverPick] = [:], appState: AppState) {
        let elapsed = tracker.job(for: eventID)?.elapsedSeconds ?? 0
        tracker.remove(eventID)

        // Only record the run's duration when something actually generated
        // (caption OR media). Otherwise an immediate failure pulls the
        // rolling-mean estimate toward zero.
        let producedSomething = result.hasAnyContent || !(mediaPaths?.isEmpty ?? true)
        if producedSomething {
            TimingStore.shared.recordGeneration(seconds: Double(elapsed))
        }

        // Base the write-back on the live event, not the snapshot taken at
        // button press: the run takes minutes, and any edits made meanwhile
        // must not be reverted.
        var saved = appState.events.first(where: { $0.id == eventID }) ?? ev

        if let only = onlyDays,
           var existing = appState.events.first(where: { $0.id == eventID })?.weekResult ?? ev.weekResult {
            // Partial retry: merge new results into the existing weekResult
            for key in only {
                if key == "blog" {
                    existing.blog = result.blog
                } else if let day = DayName(rawValue: key) {
                    existing[day] = result[day]
                }
            }
            // Clear retried errors; carry over any new ones
            for key in only { existing.errors.removeValue(forKey: key) }
            existing.errors.merge(result.errors) { _, new in new }
            saved.weekResult = existing
        } else {
            saved.weekResult = result
        }

        // A full run replaces all previews; a partial retry merges only the
        // regenerated days so other days' approved previews survive.
        saved.previewMediaPaths = PreviewMergePolicy.merge(
            existing: saved.previewMediaPaths, fresh: mediaPaths, isFullRun: onlyDays == nil)

        saved.applyFridayClipPlan(fridayClipPlan)
        for (day, pick) in coverPicks { saved.applyCoverPick(pick, forDay: day) }

        appState.updateEvent(saved)
        NotificationService.shared.notifyGenerationComplete(eventName: ev.name)
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
