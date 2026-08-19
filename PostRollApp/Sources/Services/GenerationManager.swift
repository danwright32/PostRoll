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

    /// Whether anything at all is running here, asked before the app updates
    /// itself: installing quits PostRoll (#686).
    var hasWorkInFlight: Bool { tracker.hasWorkInFlight }

    func hasFailed(_ id: Event.ID) -> Bool { tracker.hasFailed(id) }

    /// Begin (or restart) a generation for `eventID`. `retryDays` nil = full
    /// run; a set of day keys (and/or "blog") = partial retry merged into the
    /// existing weekResult.
    /// Begin a generation. `regenerateGraphics` overrides the default of
    /// graphics-only-on-full-run: pass `true` to also re-render previews for a
    /// partial retry (used when switching the posting preset, which changes the
    /// media for the affected days, not just their captions).
    /// - Parameter forcePaidPath: pin this run to the metered API whatever the
    ///   subscription switch says (#257). Set when Dan chooses to finish a
    ///   capped week by paying, so the choice holds for the run he made it on
    ///   rather than depending on a setting he did not touch.
    func start(eventID: Event.ID, retryDays: Set<String>?, appState: AppState,
               regenerateGraphics: Bool? = nil, forcePaidPath: Bool = false) {
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
            // Result, not `try?`: a graphics crash used to vanish here, and so did
            // the per-day errors of a run that exited cleanly. Either way the run
            // reported success and the day just silently had no media.
            //
            // Registered with PreviewGraphicsManager before it starts, and
            // released after (#456). This call went straight to the bridge, so
            // the duplicate-run guard #75 added did not see it: a preview run
            // started here and one started from the review screen are two
            // writers on the same MP4s and PNGs, which is the exact hazard that
            // guard exists for.
            let claimed = doGraphics && PreviewGraphicsManager.shared.beginFullRun(eventID)
            let graphicsTask: Task<Result<PythonBridge.PreviewGenerationResult, Error>?, Never>? = claimed
                ? Task {
                    defer { PreviewGraphicsManager.shared.endFullRun(eventID) }
                    do { return .success(try await PythonBridge.shared.runPreviewGeneration(
                        event: ev, days: onlyDays.map { Array($0) })) }
                    catch { return .failure(error) }
                }
                : nil

            do {
                let result = try await PythonBridge.shared.runWeekGeneration(
                    event: ev, onlyDays: onlyDays, forcePaidPath: forcePaidPath)
                let (mediaResult, mediaErrors, mediaWarnings) = await Self.graphicsOutcome(of: graphicsTask)
                self?.finishSuccess(eventID: eventID, snapshot: ev, onlyDays: onlyDays,
                                    result: result, mediaPaths: mediaResult?.paths,
                                    mediaErrors: mediaErrors,
                                    mediaWarnings: mediaWarnings,
                                    // A full graphics run owns every day's errors (nil);
                                    // a partial owns only its days; skipped owns none.
                                    renderedDays: doGraphics ? onlyDays : [],
                                    fridayClipPlan: mediaResult?.fridayClipPlan,
                                    coverPicks: mediaResult?.coverPicks ?? [:], appState: appState)
            } catch is CancellationError {
                graphicsTask?.cancel()
            } catch _ where Task.isCancelled {
                // Dan pressed Cancel. Killing the subprocess surfaces as an
                // ordinary script failure rather than a CancellationError, so
                // without this the salvage path below would merge a half
                // finished run over captions he had already edited and stamp
                // the week incomplete, having been asked to stop and do
                // nothing. A cancelled run writes nothing, as it always did.
                graphicsTask?.cancel()
            } catch let halt as WeekGenerationHalted {
                // A halt is not a crash. Everything that finished is real and
                // already paid for, so it is saved exactly as a successful run's
                // days are, and only then is the halt screen shown (#262).
                // Dropping it here is what made #257's whole feature unreachable.
                //
                // The graphics are awaited rather than cancelled: they run in a
                // separate process that a caption cap has no bearing on, and
                // throwing away a finished collage because the captions ran out
                // of allowance means rendering it again for nothing.
                let (mediaResult, mediaErrors, mediaWarnings) = await Self.graphicsOutcome(of: graphicsTask)
                self?.finishSuccess(eventID: eventID, snapshot: ev, onlyDays: onlyDays,
                                    result: halt.week, mediaPaths: mediaResult?.paths,
                                    mediaErrors: mediaErrors,
                                    mediaWarnings: mediaWarnings,
                                    renderedDays: doGraphics ? onlyDays : [],
                                    fridayClipPlan: mediaResult?.fridayClipPlan,
                                    coverPicks: mediaResult?.coverPicks ?? [:],
                                    appState: appState,
                                    haltedReason: halt.reason)
            } catch let partial as WeekGenerationFailedWithPartial {
                // The run died with days already generated, most often because
                // the watchdog killed it at 1800s. Python saved them for exactly
                // this reason (#206) and nothing read the file, so they were
                // thrown away with the temp directory (#262). Saved first, then
                // the failure is shown: this is still the error screen, because
                // there is no cap and no choice to offer.
                //
                // The graphics are awaited for the same reason as the halt
                // above: they render in a separate process that a dead caption
                // run has no bearing on, and cancelling them throws away
                // collages and reels that had already finished.
                let (mediaResult, mediaErrors, mediaWarnings) = await Self.graphicsOutcome(of: graphicsTask)
                self?.saveSalvagedDays(eventID: eventID, snapshot: ev,
                                       week: partial.week,
                                       mediaPaths: mediaResult?.paths,
                                       mediaErrors: mediaErrors,
                                       mediaWarnings: mediaWarnings,
                                       renderedDays: doGraphics ? onlyDays : [],
                                       appState: appState)
                self?.finishFailure(eventID: eventID,
                                    message: ((partial as? PythonBridgeError)?.message(whileDoing: .generation) ?? partial.localizedDescription))
            } catch {
                graphicsTask?.cancel()
                self?.finishFailure(eventID: eventID, message: ((error as? PythonBridgeError)?.message(whileDoing: .generation) ?? error.localizedDescription))
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

    /// Fold the parallel graphics run's outcome into the two things every
    /// completion path needs. One implementation, because three copies of it is
    /// three places for a fix to land in only one.
    private static func graphicsOutcome(
        of task: Task<Result<PythonBridge.PreviewGenerationResult, Error>?, Never>?
    ) async -> (PythonBridge.PreviewGenerationResult?, [String: String], [String: String]) {
        switch await task?.value {
        case .success(let r):
            return (r, r.errors, r.warnings)
        case .failure(let error):
            return (nil, [PreviewMergePolicy.graphicsRunKey: ((error as? PythonBridgeError)?.message(whileDoing: .generation) ?? error.localizedDescription)], [:])
        case nil:
            return (nil, [:], [:])   // graphics didn't run this time
        }
    }

    private func finishSuccess(eventID: Event.ID, snapshot ev: Event, onlyDays: Set<String>?,
                               result: WeekGenerationResult, mediaPaths: [String: [String: String]]?,
                               mediaErrors: [String: String] = [:],
                               mediaWarnings: [String: String] = [:],
                               renderedDays: Set<String>? = nil,
                               fridayClipPlan: FridayClipPlan? = nil,
                               coverPicks: [String: CoverPick] = [:], appState: AppState,
                               haltedReason: String? = nil) {
        let elapsed = tracker.job(for: eventID)?.elapsedSeconds ?? 0
        // A halted run keeps its job so the halt screen has something to render
        // from; an ordinary success is done and the job goes.
        if haltedReason == nil { tracker.remove(eventID) }

        // Only record the run's duration when something actually generated
        // (caption OR media). Otherwise an immediate failure pulls the
        // rolling-mean estimate toward zero.
        //
        // A halted run is excluded for the same reason: it stopped after two
        // days in ninety seconds, and feeding that to the mean that estimates a
        // full week makes every later run's estimate expire before it finishes.
        let producedSomething = result.hasAnyContent || !(mediaPaths?.isEmpty ?? true)
        if producedSomething && haltedReason == nil {
            TimingStore.shared.recordGeneration(seconds: Double(elapsed))
        }

        // Base the write-back on the live event, not the snapshot taken at
        // button press: the run takes minutes, and any edits made meanwhile
        // must not be reverted.
        var saved = appState.events.first(where: { $0.id == eventID }) ?? ev

        // One decision, made in one place. Ordering these branches by hand here
        // is what let a halted partial retry take the ordinary merge path and
        // nil out days it had never reached.
        saved.weekResult = PartialWeekMerge.merged(
            existing: saved.weekResult ?? ev.weekResult,
            incoming: result,
            onlyDays: onlyDays,
            ending: haltedReason == nil ? .finished : .stoppedEarly)

        // A full run replaces all previews; a partial retry merges only the
        // regenerated days so other days' approved previews survive.
        saved.previewMediaPaths = PreviewMergePolicy.merge(
            existing: saved.previewMediaPaths, fresh: mediaPaths, isFullRun: onlyDays == nil)

        // Graphics failures are recorded, not dropped: a day whose collage or reel
        // died has to say so on the asset screen instead of just showing nothing.
        saved.mediaErrors = PreviewMergePolicy.mergeMediaErrors(
            existing: saved.mediaErrors, fresh: mediaErrors, renderedDays: renderedDays)
        // Same merge rule, its own store: a warning about a day this run never
        // re-rendered must not be erased either (#265).
        saved.mediaWarnings = PreviewMergePolicy.mergeMediaErrors(
            existing: saved.mediaWarnings, fresh: mediaWarnings, renderedDays: renderedDays)

        // A re-rendered reel carries music this run fetched, so a label written
        // by an earlier manual swap now names a track the file does not contain.
        saved = ReelAudioSwap.clearingStaleAudioLabels(in: saved, freshMedia: mediaPaths)

        saved.applyFridayClipPlan(fridayClipPlan)
        for (day, pick) in coverPicks { saved.applyCoverPick(pick, forDay: day) }

        appState.updateEvent(saved)

        // A halted week is saved but NOT announced as complete, and the run goes
        // to the failed state so FailureScreen routes it to the halt screen with
        // its two ways forward. Telling Dan a capped week "finished" would be
        // the app claiming more than it measured (L12).
        if let haltedReason {
            finishFailure(eventID: eventID, message: haltedReason)
            return
        }
        NotificationService.shared.notifyGenerationComplete(eventName: ev.name)
    }

    /// Keep the days a dead run had already produced, without any of the
    /// success bookkeeping (#262).
    ///
    /// Deliberately not `finishSuccess`: nothing here should record a duration,
    /// send a completion notification, or replace the saved previews. The run
    /// failed. The only claim being made is that these particular days exist,
    /// which is a claim the results file supports.
    private func saveSalvagedDays(eventID: Event.ID, snapshot ev: Event,
                                  week: WeekGenerationResult,
                                  mediaPaths: [String: [String: String]]?,
                                  mediaErrors: [String: String],
                                  mediaWarnings: [String: String],
                                  renderedDays: Set<String>?,
                                  appState: AppState) {
        var saved = appState.events.first(where: { $0.id == eventID }) ?? ev
        // The same merge as a halt, and for the same reason: days this run never
        // reached must not erase days an earlier run generated (L5).
        saved.weekResult = PartialWeekMerge.applying(week, onto: saved.weekResult)
        // The graphics finished in their own process and are on disk. Not
        // keeping them means re-rendering work that is already done.
        saved.previewMediaPaths = PreviewMergePolicy.merge(
            existing: saved.previewMediaPaths, fresh: mediaPaths, isFullRun: false)
        saved.mediaErrors = PreviewMergePolicy.mergeMediaErrors(
            existing: saved.mediaErrors, fresh: mediaErrors, renderedDays: renderedDays)
        saved.mediaWarnings = PreviewMergePolicy.mergeMediaErrors(
            existing: saved.mediaWarnings, fresh: mediaWarnings, renderedDays: renderedDays)
        saved = ReelAudioSwap.clearingStaleAudioLabels(in: saved, freshMedia: mediaPaths)
        appState.updateEvent(saved)
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
