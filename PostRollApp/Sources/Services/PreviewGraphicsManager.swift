import Foundation
import Observation

/// Owns preview-graphic generation at app scope, keyed by event id.
///
/// CaptionReviewView used to hold this in `@State` and auto-start it from
/// `onAppear` with no in-flight guard. Because `EventDetailView` remounts the
/// screen via `.id(event.id)` on every event switch, switching away and back
/// during the roughly one-minute run started a second concurrent run writing
/// the same files, while the remounted screen showed no spinner at all (#75).
///
/// Mirrors GenerationManager, ExportManager and OCRManager: the run outlives
/// the view, the write-back goes through AppState rather than view state, and
/// the progress is derived from here so a remount re-shows it.
@MainActor
@Observable
final class PreviewGraphicsManager {
    static let shared = PreviewGraphicsManager()

    private(set) var state = PreviewRunState()
    /// Last failure per event, so a run that died isn't just an idle screen.
    private(set) var failures: [UUID: String] = [:]

    func isGenerating(_ eventID: UUID) -> Bool { state.isRunningFull(eventID) }
    func startedAt(_ eventID: UUID) -> Date? { state.fullRunStartedAt(eventID) }
    func regeneratingDays(_ eventID: UUID) -> Set<DayName> { state.regeneratingDays(for: eventID) }
    func failure(for eventID: UUID) -> String? { failures[eventID] }
    func clearFailure(for eventID: UUID) { failures.removeValue(forKey: eventID) }

    /// Runs the full preview generation and writes the result back through
    /// `appState`. A no-op when one is already in flight for this event.
    /// `onFinish` runs on the main actor after the write-back, whether the run
    /// succeeded or failed, so a view can follow up without owning the run.
    func startFullRun(eventID: UUID, appState: AppState, onFinish: (@MainActor () -> Void)? = nil) {
        guard state.beginFullRun(eventID) else { return }
        failures.removeValue(forKey: eventID)
        Task {
            defer {
                state.endFullRun(eventID)
                onFinish?()
            }
            guard let live = appState.events.first(where: { $0.id == eventID }) else { return }
            do {
                let result = try await PythonBridge.shared.runPreviewGeneration(event: live)
                guard !result.paths.isEmpty else { return }
                // Live read at write-back: the run takes a minute or more and a
                // snapshot would revert anything edited in between.
                guard var ev = appState.events.first(where: { $0.id == eventID }) else { return }
                ev.previewMediaPaths = result.paths
                ev.applyFridayClipPlan(result.fridayClipPlan)
                for (day, pick) in result.coverPicks { ev.applyCoverPick(pick, forDay: day) }
                appState.updateEvent(ev)
            } catch {
                // Loud, not silent: this used to be a `try?`, so a failed run
                // left the screen looking like a finished one with no graphics.
                failures[eventID] = error.localizedDescription
            }
        }
    }

    /// Marks a single day as regenerating. Returns false when it already is, so
    /// the caller skips launching a duplicate.
    @discardableResult
    func beginDayRegen(_ day: DayName, for eventID: UUID) -> Bool {
        state.beginDay(day, for: eventID)
    }

    func endDayRegen(_ day: DayName, for eventID: UUID) {
        state.endDay(day, for: eventID)
    }
}
