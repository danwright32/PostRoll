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

    /// Claim the full preview run for an event without this manager driving it.
    ///
    /// For GenerationManager, which runs its own graphics pass alongside the
    /// captions and went straight to the bridge, so the duplicate-run guard did
    /// not see it (#456). Returns false when a run is already in flight, in
    /// which case the caller must not start another: two runs are two writers
    /// on the same MP4s and PNGs.
    @discardableResult
    func beginFullRun(_ eventID: UUID) -> Bool {
        state.beginFullRun(eventID)
    }

    func endFullRun(_ eventID: UUID) {
        state.endFullRun(eventID)
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

    /// When this day's regen started, for the elapsed time on its spinner.
    func dayStartedAt(_ day: DayName, for eventID: UUID) -> Date? {
        state.dayStartedAt(day, for: eventID)
    }

    // MARK: - Cover regeneration (#141, moved here by #456)

    @discardableResult
    func beginCoverRegen(_ day: DayName, for eventID: UUID) -> Bool {
        state.beginCover(day, for: eventID)
    }

    func endCoverRegen(_ day: DayName, for eventID: UUID) {
        state.endCover(day, for: eventID)
    }

    func coverRegeneratingDays(_ eventID: UUID) -> Set<DayName> {
        state.coverRegeneratingDays(for: eventID)
    }

    func coverStartedAt(_ day: DayName, for eventID: UUID) -> Date? {
        state.coverStartedAt(day, for: eventID)
    }

    // MARK: - Thursday reel editor (#456)

    /// The built editor image for an event, and whether a build is running.
    ///
    /// Held here rather than in the review screen's `@State`, because the
    /// `.id(event.id)` remount discarded both: switching away and back during
    /// the build restarted it while the orphan was still running, and the
    /// finished URL was thrown away.
    private var thursdayEditor: [UUID: URL] = [:]
    private var buildingThursdayEditor: Set<UUID> = []
    /// Why the last build did not produce an editor. Its own field because a
    /// build that failed and a build that has not run yet are different
    /// screens: the failed one used to sit on "Loading…" forever, which is the
    /// spinner-over-a-failure shape (L10).
    private var thursdayEditorFailures: [UUID: String] = [:]

    func thursdayEditorURL(_ eventID: UUID) -> URL? { thursdayEditor[eventID] }
    func isBuildingThursdayEditor(_ eventID: UUID) -> Bool {
        buildingThursdayEditor.contains(eventID)
    }
    func thursdayEditorFailure(_ eventID: UUID) -> String? { thursdayEditorFailures[eventID] }

    /// Returns false when a build is already running for this event, in which
    /// case the caller must not start another: both write the same PNG and
    /// layout JSON.
    @discardableResult
    func beginThursdayEditorBuild(_ eventID: UUID) -> Bool {
        guard buildingThursdayEditor.insert(eventID).inserted else { return false }
        thursdayEditorFailures.removeValue(forKey: eventID)
        return true
    }

    func finishThursdayEditorBuild(_ eventID: UUID, url: URL?) {
        buildingThursdayEditor.remove(eventID)
        if let url { thursdayEditor[eventID] = url }
    }

    /// The build threw. Said out loud rather than left as a spinner: this used
    /// to be a `try?`, so a failed build was indistinguishable from a slow one
    /// and the card sat on "Loading…" for as long as it was open.
    func failThursdayEditorBuild(_ eventID: UUID, reason: String) {
        buildingThursdayEditor.remove(eventID)
        thursdayEditorFailures[eventID] = reason
    }

    /// Drop a built editor whose inputs have changed, so the next expand
    /// rebuilds it rather than showing a strip of the previous photos.
    func invalidateThursdayEditor(_ eventID: UUID) {
        thursdayEditor.removeValue(forKey: eventID)
    }

    // MARK: - Speculative reel pre-render (#456)

    private var speculativeReels: [UUID: SpeculativeReelRenderer] = [:]

    /// The pre-renderer for one event, created once and kept.
    ///
    /// It was a `@State` value, so the remount took its anti-collision guard
    /// down with it: the orphaned encode kept writing reel.mp4 while the fresh
    /// instance, knowing nothing about it, started a second ffmpeg writing the
    /// same file.
    func speculativeReel(for eventID: UUID) -> SpeculativeReelRenderer {
        if let existing = speculativeReels[eventID] { return existing }
        let made = SpeculativeReelRenderer(day: .thursday)
        speculativeReels[eventID] = made
        return made
    }
}
