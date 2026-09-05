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

    #if POSTROLL_TESTS
    /// Test seam: the real one shells out to Python and renders a week of
    /// media, which no test may do (L2).
    ///
    /// Takes the event it renders as an argument rather than reading one, so a
    /// test can see WHICH event a run was built from. That is the whole
    /// question behind #1010: the claim is taken before the caller writes its
    /// switch, so a run built from the event as it stood at claim time renders
    /// the layout the switch is moving away from.
    var renderPreview: @Sendable (Event, [String]?)
        async throws -> PythonBridge.PreviewGenerationResult = {
            try await PythonBridge.shared.runPreviewGeneration(event: $0, days: $1)
        }
    #else
    let renderPreview: @Sendable (Event, [String]?)
        async throws -> PythonBridge.PreviewGenerationResult = {
            try await PythonBridge.shared.runPreviewGeneration(event: $0, days: $1)
        }
    #endif

    private(set) var state = PreviewRunState()
    /// Last failure per event, so a run that died isn't just an idle screen.
    private(set) var failures: [UUID: String] = [:]

    func isGenerating(_ eventID: UUID) -> Bool { state.isRunningFull(eventID) }
    func startedAt(_ eventID: UUID) -> Date? { state.fullRunStartedAt(eventID) }

    /// The full runs in flight, so one can be stopped (#1050).
    ///
    /// This owner does not compose a `JobTracker`, so it got none of the
    /// stopping the tracker gained, and it was invisible to a sweep looking for
    /// one: enumerating by that spelling missed the action that reaches the
    /// same state by another route (L247). It is a minute of rendering behind a
    /// spinner, which is exactly the shape #1050 is about.
    private var fullRunTasks: [UUID: Task<Void, Never>] = [:]

    /// Which runs have been asked to stop and have not stopped yet.
    private var stopping: Set<UUID> = []

    /// Stop the full preview run for this event.
    ///
    /// Returns whether the request was taken, so a caller can tell a stop from
    /// a press that arrived after the work was already over (L197).
    @discardableResult
    func stop(_ eventID: UUID) -> Bool {
        guard let task = fullRunTasks[eventID], !stopping.contains(eventID) else {
            return false
        }
        stopping.insert(eventID)
        task.cancel()
        return true
    }

    /// A stop was asked for and the work has not stopped yet.
    func isStopping(_ eventID: UUID) -> Bool {
        stopping.contains(eventID) && isGenerating(eventID)
    }
    func regeneratingDays(_ eventID: UUID) -> Set<DayName> { state.regeneratingDays(for: eventID) }
    func failure(for eventID: UUID) -> String? { failures[eventID] }
    func clearFailure(for eventID: UUID) { failures.removeValue(forKey: eventID) }

    /// How many times this day's graphic has been rebuilt (#1009).
    ///
    /// The number a rendered image is keyed on, so the view reloads the file
    /// rather than showing the copy it already decoded. It was `@State` on the
    /// caption review screen, so a redraw driven from anywhere else finished
    /// and left that screen showing the previous collage with nothing saying so.
    func graphicVersion(_ day: DayName, for eventID: UUID) -> Int {
        state.graphicVersion(day, for: eventID)
    }

    func bumpGraphicVersion(_ day: DayName, for eventID: UUID) {
        state.bumpGraphicVersion(day, for: eventID)
    }

    /// Runs the full preview generation and writes the result back through
    /// `appState`. A no-op when one is already in flight for this event.
    /// `onFinish` runs on the main actor after the write-back, whether the run
    /// succeeded or failed, so a view can follow up without owning the run.
    func startFullRun(eventID: UUID, appState: AppState, onFinish: (@MainActor () -> Void)? = nil) {
        guard state.beginFullRun(eventID) else { return }
        failures.removeValue(forKey: eventID)
        // A fresh run was not stopped, whatever happened to the last one under
        // this id. Left behind, the record would make the new run report itself
        // as winding down the moment it started (L186).
        stopping.remove(eventID)
        let held = Task { @MainActor [weak self] in
            defer {
                self?.state.endFullRun(eventID)
                self?.fullRunTasks.removeValue(forKey: eventID)
                onFinish?()
            }
            guard let live = appState.events.first(where: { $0.id == eventID }) else { return }
            do {
                let result = try await self?.renderPreview(live, nil)
                guard let result else { return }
                self?.applyFullRunResult(result, for: eventID, appState: appState)
            } catch is CancellationError {
                // Dan pressed stop (#1050). Not a failure: a red banner over
                // something he asked for would be a claim about what happened
                // (L11).
            } catch {
                // Loud, not silent: this used to be a `try?`, so a failed run
                // left the screen looking like a finished one with no graphics.
                self?.failures[eventID] = error.localizedDescription
            }
        }
        // Held so the run can be stopped. It was a bare `Task { }` and the
        // handle went straight in the bin (#1050).
        fullRunTasks[eventID] = held
    }

    /// Land a finished full run: the days that rendered, and the days that did
    /// not (#740).
    ///
    /// This used to write `result.paths` and stop, behind a `guard
    /// !result.paths.isEmpty`, so the run where every day failed was the one
    /// that recorded nothing at all. A day that died inside the whole week
    /// rebuild left no failure here, no `mediaErrors` entry, and nothing on
    /// screen saying why, while the same failure from the per-day rebuild was
    /// reported in all three places.
    ///
    /// Its own method rather than a closure body inside `startFullRun`, because
    /// what a finished result MEANS is the half that was missing and the half
    /// worth testing: the run itself goes to a real subprocess.
    func applyFullRunResult(_ result: PythonBridge.PreviewGenerationResult,
                            for eventID: UUID, appState: AppState) {
        // Live read at write-back: the run takes a minute or more and a
        // snapshot would revert anything edited in between.
        guard var ev = appState.events.first(where: { $0.id == eventID }) else { return }

        // A run that said NOTHING is not a run that found nothing wrong.
        // `runPreviewGeneration` answers with a wholly empty result when Python
        // wrote no output file, or wrote something that would not parse, and
        // folding that in as this run's answer erases every stored error and
        // warning the event had: a read that comes back empty when it FAILS
        // destroys the whole record the first time it fails, at the moment the
        // record is worth having (L105).
        //
        // Caught in the running app after this method shipped in #740. The
        // caption screen auto-starts a graphics run for an event with no
        // previews yet, that run reported nothing, and every day's stored
        // warning went with it.
        //
        // Emptiness in all three, deliberately: a run that rendered the week
        // and found nothing wrong carries paths, and it MUST still take away
        // the failures the run before recorded, or a day that has been fixed
        // reports as broken forever (L14).
        guard !result.paths.isEmpty || !result.errors.isEmpty || !result.warnings.isEmpty
        else { return }

        // The same fold a generation run's graphics pass uses, with the same
        // argument: a full run owns every day, so its answer replaces the lot
        // and a day it fixed stops reporting an error from the run before.
        // One implementation, so the two full-run paths cannot drift.
        ev.mediaErrors = PreviewMergePolicy.mergeMediaErrors(
            existing: ev.mediaErrors, fresh: result.errors, renderedDays: nil)
        // Same merge rule, its own store: a day that rendered without an
        // optional photo is not a day with no graphics (#265).
        ev.mediaWarnings = PreviewMergePolicy.mergeMediaErrors(
            existing: ev.mediaWarnings, fresh: result.warnings, renderedDays: nil)

        if !result.paths.isEmpty {
            ev.previewMediaPaths = result.paths
            ev.recordRenderedLayout(
                ev.effectivePostingPreset,
                forDays: PreviewMergePolicy.renderedDays(in: result.paths))
            ev.applyFridayClipPlan(result.fridayClipPlan)
            for (day, pick) in result.coverPicks { ev.applyCoverPick(pick, forDay: day) }
        }
        appState.updateEvent(ev)

        // A full run owns every day, so it speaks for all of them.
        recordDayOutcomes(errors: result.errors, paths: result.paths,
                          renderedDays: nil, for: eventID)
    }

    /// Land a graphics pass's per-day outcomes: a failure recorded for every
    /// day it reported one, and the reason from the run before taken away from
    /// every day it rebuilt successfully.
    ///
    /// Shared by the two entry points a full preview pass has, rather than one
    /// implementation each. `applyFullRunResult` above is the run started from
    /// the caption review screen (#740); `GenerationManager` runs its own pass
    /// alongside the captions and recorded none of this, so a day that died
    /// during a whole week generation left no failure row on that screen and
    /// Friday's "< 3 usable clips" escape hatch, which is reached FROM the
    /// recorded failure, was unreachable for it (#750). Two implementations is
    /// two places for the next fix to land in only one.
    ///
    /// `renderedDays` is the set of days this pass actually re-rendered, in the
    /// same currency `PreviewMergePolicy.mergeMediaErrors` takes: nil for a full
    /// run, which owns every day, and empty for a caption-only retry that
    /// skipped graphics entirely and may therefore take nothing away (L5).
    func recordDayOutcomes(errors: [String: String],
                           paths: [String: [String: String]],
                           renderedDays: Set<String>?, for eventID: UUID) {
        // Walked in the week's own order rather than over the dictionary, so a
        // key that names no day (the run-level `graphics` key a generation run
        // can write) is skipped by construction rather than by a filter.
        let rebuildingOnTheirOwn = state.regeneratingDays(for: eventID)
        for day in DayName.allCases {
            guard renderedDays?.contains(day.rawValue) ?? true else { continue }
            // A per-day rebuild claimed while this run was in flight owns that
            // day's outcome. This run's answer for it is about the inputs as
            // they stood before that rebuild started, and `failDayRegen`
            // records AND releases the slot, so landing it here would take down
            // a live rebuild's in-flight marker while its subprocess ran on,
            // leaving the day free to be started a third time: two writers on
            // one MP4, which is the hazard #75 exists for.
            guard !rebuildingOnTheirOwn.contains(day) else { continue }
            if let pipelineError = errors[day.rawValue] {
                // Through the recording call the per-day path uses, not a
                // second implementation beside it: the pipeline marks the cases
                // it has a remedy for with a prefix, and Friday's "< 3 usable
                // clips" escape hatch is reached from the recorded failure, so
                // the marker has to survive to the card that offers it (#730).
                failDayRegen(day, for: eventID, pipelineError: pipelineError)
            } else if paths[day.rawValue]?.isEmpty == false {
                // This run rebuilt the day and it worked, so the reason left by
                // the run before is no longer true. Only for a day that
                // actually produced something: a day this run never reached
                // must keep its failure, or a rebuild would silently erase a
                // reason it never re-attempted (L5).
                clearDayFailure(day, for: eventID)
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
    ///
    /// Deliberately NOT `@discardableResult`. It was, and four of the five
    /// callers on the caption review screen started their run regardless, which
    /// nothing anywhere reported: two subprocesses writing one MP4, and the
    /// annotation is what stopped the compiler naming who (#728). A caller that
    /// genuinely means to ignore the answer has to write `_ =` and say why.
    func beginDayRegen(_ day: DayName, for eventID: UUID) -> Bool {
        guard state.beginDay(day, for: eventID) else { return false }
        // This slot's own reason only. A stored error outliving the run it was
        // about reads as a failure happening now, and clearing the day's
        // neighbours would take away reasons that are still true (#721).
        clearDayFailure(day, for: eventID)
        return true
    }

    /// Claim several days at once, all of them or none (#728).
    ///
    /// Two actions on the review screen rebuild Tuesday and Friday from one
    /// shared write, and half of that write landing is the state this prevents:
    /// Friday carrying the new photos with the old graphic still rendered.
    ///
    /// Checked before anything is claimed rather than claimed and rolled back,
    /// because claiming a day CLEARS its stored failure (#721) and a rollback
    /// cannot put that back: a refused pair would take away a reason Dan has not
    /// read yet while starting nothing at all. Two steps are safe here because
    /// this is the main actor throughout, so nothing can interleave between
    /// them.
    ///
    /// An empty list is refused. Nothing to rebuild is not a rebuild, and
    /// answering yes would have the caller persist its write and wait for a run
    /// nobody started (L98).
    func beginDayRegen(_ days: [DayName], for eventID: UUID) -> Bool {
        guard !days.isEmpty else { return false }
        let busy = state.regeneratingDays(for: eventID)
        guard days.allSatisfy({ !busy.contains($0) }) else { return false }
        for day in days { _ = beginDayRegen(day, for: eventID) }
        return true
    }

    func endDayRegen(_ day: DayName, for eventID: UUID) {
        state.endDay(day, for: eventID)
    }

    /// When this day's regen started, for the elapsed time on its spinner.
    func dayStartedAt(_ day: DayName, for eventID: UUID) -> Date? {
        state.dayStartedAt(day, for: eventID)
    }

    // MARK: - Cover regeneration (#141, moved here by #456)

    /// Not `@discardableResult`, for the same reason as `beginDayRegen`: the
    /// answer is the only thing stopping two runs on one file (#728).
    func beginCoverRegen(_ day: DayName, for eventID: UUID) -> Bool {
        guard state.beginCover(day, for: eventID) else { return false }
        clearCoverFailure(day, for: eventID)
        return true
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

    // MARK: - What a failed rebuild left to say (#721)

    /// One rebuild slot: an event and a day.
    private struct DaySlot: Hashable {
        let eventID: UUID
        let day: DayName
    }

    /// A slot that failed, and why. Ordered by the week rather than by a
    /// dictionary, so a list of them cannot reshuffle between redraws.
    struct DayFailure: Equatable {
        let day: DayName
        /// The sentence Dan reads.
        let reason: String
        /// The Python side's own error, when that is what failed, kept beside
        /// the sentence rather than only inside it (#730).
        ///
        /// `generate_media.py` marks the cases it has a remedy for with a
        /// prefix, `insufficient_clips:` being the one with an escape hatch on
        /// screen. The screen used to wrap that into "Friday regeneration
        /// failed: …" and record only the wrapping, so the prefix sat mid
        /// sentence, the card's prefix check could never match, and the one
        /// failure with a way out was the one shown without it.
        ///
        /// nil for the failures that have no marker to keep: a track that could
        /// not be fetched, a copy that failed, a run that produced no output.
        /// Those are prose by nature, and an empty value here is that fact
        /// rather than a forgotten argument, which is why the two ways of
        /// recording a failure are separate calls below.
        let pipelineError: String?
    }

    /// Why a day's rebuild failed, and why a day's cover rebuild failed, kept
    /// apart per slot (#721).
    ///
    /// All of this used to be one `@State` string on the caption review screen,
    /// written by the audio swap, the cover rebuild, the Friday reel edit and
    /// the per-day rebuild alike. Two things were wrong with that. Independent
    /// actions sharing one status field means whichever failed last erased the
    /// reason before it (L53). And these runs are owned HERE precisely because
    /// they outlive the screen, so a swap that failed while Dan was on another
    /// event had its message destroyed with the view while the run itself
    /// carried on (L148).
    ///
    /// One field per in flight SLOT, not per message: a day's rebuild and its
    /// cover rebuild are two separate slots that can run at once, and two
    /// actions occupying one slot cannot both be running to disagree.
    private var dayFailures: [DaySlot: Recorded] = [:]
    private var coverFailures: [DaySlot: String] = [:]

    /// One day slot's failure as stored: the day is the key, so only what the
    /// key does not already say is kept here.
    private struct Recorded {
        let reason: String
        let pipelineError: String?
    }

    /// This day's failure whole, so a caller deciding from it reads the marker
    /// rather than the sentence (#730). `FridayReviewDisplay` takes this type
    /// and not a string for that reason: prose cannot be handed to a prefix
    /// check by mistake if the check does not accept prose.
    func dayFailure(_ day: DayName, for eventID: UUID) -> DayFailure? {
        dayFailures[DaySlot(eventID: eventID, day: day)].map {
            DayFailure(day: day, reason: $0.reason, pipelineError: $0.pipelineError)
        }
    }

    func coverFailure(_ day: DayName, for eventID: UUID) -> String? {
        coverFailures[DaySlot(eventID: eventID, day: day)]
    }

    // MARK: - Redraw a day's images without touching its caption (#1010)

    /// Redraw these days' images, with no caption run anywhere near it (#1010).
    ///
    /// Claims BEFORE anything else happens and answers false if it cannot, so
    /// a caller that has to mutate the event first can find out it was refused
    /// while there is still nothing to undo (L197).
    ///
    /// Returns whether the run started. Not `@discardableResult`, for the same
    /// reason `beginDayRegen` is not: the answer is the only thing standing
    /// between this and a second writer on the same files (#728).
    func startRedraw(_ days: [DayName], for eventID: UUID, appState: AppState) -> Bool {
        guard !days.isEmpty else { return false }
        // Claimed against an event that is really there, but deliberately NOT
        // rendered from the copy read here.
        guard appState.events.contains(where: { $0.id == eventID }) else { return false }
        guard beginDayRegen(days, for: eventID) else { return false }

        Task { [weak self] in
            guard let self else { return }
            // Read at RUN time, never at claim time (#1010).
            //
            // The claim is taken BEFORE the caller writes its switch, on
            // purpose, so a refusal costs nothing and leaves nothing to undo
            // (L197, L5). That ordering is exactly what makes a snapshot taken
            // back there wrong: it still carries the layout the switch is
            // moving AWAY from, and the manifest handed to Python carries
            // `effectivePostingPreset`. A Balanced to Opening switch on a
            // Sunday with seven photos redrew it at four again, landed the
            // identical images, and reported a finished switch that changed
            // nothing at all.
            //
            // Safe because the caller writes synchronously: this body is
            // enqueued on the main actor, and there is no await between the
            // caller's claim and its write for it to run in.
            guard let live = appState.events.first(where: { $0.id == eventID }) else {
                // The event went away between the claim and the run. Release
                // every slot rather than leaving spinners on days nothing will
                // ever finish (L110).
                for day in days { self.endDayRegen(day, for: eventID) }
                return
            }

            let outcome: Result<PythonBridge.PreviewGenerationResult, Error>
            do {
                outcome = .success(try await self.renderPreview(live, days.map(\.rawValue)))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                switch outcome {
                case .success(let result):
                    self.applyRedraw(result, days: days, for: eventID, appState: appState)
                case .failure(let error):
                    // A run that DIED says nothing per day, so every day it
                    // claimed has to be failed by hand or each keeps a spinner
                    // for work that already stopped (L110).
                    for day in days {
                        self.failDayRegen(
                            day, for: eventID,
                            reason: "\(day.displayName) images could not be redrawn: "
                                  + "\(error.localizedDescription)")
                    }
                    // A run that died is a finished switch too, and the one
                    // most worth saying out loud: every day it claimed is back
                    // where it started (#1046).
                    self.announce(landed: [], failed: days,
                                  for: eventID, appState: appState)
                }
            }
        }
        return true
    }

    /// Render a day whose slot is ALREADY claimed, and land what comes back.
    ///
    /// The day scoped driver, callable from any screen (#1009). It was
    /// `CaptionReviewView.renderClaimedDay`: private, on a SwiftUI view, with
    /// the landing and the asset screen's bookkeeping as two more private
    /// methods beside it. No other screen could redraw a day's images.
    ///
    /// Split from the claim rather than claiming here, because two actions on
    /// the review screen claim Tuesday and Friday together and then render
    /// both, and a claim in here would refuse its own caller.
    func renderClaimedDay(_ day: DayName, for eventID: UUID, appState: AppState,
                          newLayout: Bool = false) {
        guard appState.events.contains(where: { $0.id == eventID }) else {
            // Nothing to render from. The slot is released rather than left
            // spinning for work nobody is doing (L110).
            endDayRegen(day, for: eventID)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            // The live event at RUN time, for the same reason `startRedraw`
            // reads one: whatever the caller wrote while claiming this day is
            // the state that has to be rendered, and a copy read before the
            // claim describes the day as it was before the change.
            guard let live = appState.events.first(where: { $0.id == eventID }) else {
                self.endDayRegen(day, for: eventID)
                return
            }
            // Thursday first tries to adopt a speculative pre-render, kicked
            // off when Dan edited. `newLayout` randomizes the seed, so there is
            // nothing pre-rendered that matches and a fresh encode is the only
            // answer.
            if day == .thursday, !newLayout,
               let adopted = await self.speculativeReel(for: eventID)
                                       .take(matching: live) {
                self.landRender(adopted, day: day, for: eventID, appState: appState)
                return
            }
            // No usable pre-render: make sure no stale speculative encode is
            // still writing the same output file before starting a fresh one.
            if day == .thursday { self.speculativeReel(for: eventID).cancelAll() }

            // The result is captured so that "Python crashed" and "Python
            // exited zero and reported a per day error" stay different answers.
            // Both were once swallowed by a `try?`, which fired the completion
            // notice while the mockup went on showing the old MP4.
            let outcome: Result<PythonBridge.PreviewGenerationResult, Error>
            do {
                outcome = .success(try await self.renderPreview(live, [day.rawValue]))
            } catch {
                outcome = .failure(error)
            }

            switch outcome {
            case .failure(let error):
                // A run that DIED reports nothing per day, so the day it
                // claimed has to be failed by hand or it keeps a spinner for
                // work that has already stopped (L110).
                self.failDayRegen(
                    day, for: eventID,
                    reason: "\(day.displayName) regeneration failed: "
                          + "\(error.localizedDescription)")
            case .success(let result):
                self.landRender(result, day: day, for: eventID, appState: appState)
            }
        }
    }

    /// Land a render and, when the day actually landed, say so.
    ///
    /// The notice is sent here rather than inside `applyDayRender`, so the
    /// landing can be shared with the redraw path below without a posting
    /// layout switch announcing one finished rebuild per day it touched: that
    /// is one action Dan took, not three.
    private func landRender(_ result: PythonBridge.PreviewGenerationResult,
                            day: DayName, for eventID: UUID, appState: AppState) {
        guard applyDayRender(result, day: day, for: eventID, appState: appState)
        else { return }
        // The live name, read after the write: the run takes a minute or more
        // and the event may have been renamed while it ran.
        guard let name = appState.events.first(where: { $0.id == eventID })?.name
        else { return }
        NotificationService.shared.notifyRegenerationComplete(
            eventName: name, what: day.displayName)
    }

    /// Record (or clear) what the last render said about a day, onto the live
    /// event, so the asset screen's list agrees with the screen the render was
    /// driven from (#1009).
    ///
    /// Its own call as well as part of `applyDayRender`, because a Friday reel
    /// edit re-renders one file without going through a day render at all and
    /// still has to say what came back. Both are passed every time and nil
    /// CLEARS: these describe the LAST render of that day, and a note kept past
    /// the render it was about is not merely stale, it is false (#824).
    func recordMediaOutcome(day: DayName, for eventID: UUID, appState: AppState,
                            error: String?, warning: String?) {
        guard var ev = appState.events.first(where: { $0.id == eventID }) else { return }
        guard ev.recordMediaOutcome(day: day.rawValue, error: error, warning: warning)
        else { return }
        appState.updateEvent(ev)
    }

    /// Land a finished redraw onto the live event, day by day.
    ///
    /// A loop over `applyDayRender` rather than a landing of its own (#1009).
    /// It was a second implementation beside the review screen's private one,
    /// which is two places for the next fix to land in and one of them to be
    /// forgotten: what a day reporting nothing means, what a failure has to
    /// leave behind, which stored note a successful render takes away.
    ///
    /// Deliberately does NOT touch captions. That is the whole point of #1010:
    /// a switch that only changes how many photos a day posts needs its images
    /// redrawn and its caption left exactly as Dan left it. It announces
    /// nothing either, for the reason `landRender` records.
    func applyRedraw(_ result: PythonBridge.PreviewGenerationResult,
                     days: [DayName],
                     for eventID: UUID,
                     appState: AppState) {
        // Each day judged alone, so one day's failure does not take away
        // another day's finished work (L53).
        var landed: [DayName] = []
        var failed: [DayName] = []
        for day in days {
            if applyDayRender(result, day: day, for: eventID, appState: appState) {
                landed.append(day)
            } else {
                failed.append(day)
            }
        }
        announce(landed: landed, failed: failed, for: eventID, appState: appState)
    }

    /// One notice for a whole layout switch (#1046).
    ///
    /// `landRender` announces a single day as it lands, and this path
    /// deliberately does not go through it: notifying per day would report
    /// three finished rebuilds for one thing Dan did. The cost of that was
    /// silence, for a run of several minutes, so a finished switch and one
    /// still going looked identical unless he watched the screen (#95).
    ///
    /// Sent from the answer `applyDayRender` gives rather than from the fact
    /// the run returned, so a switch where days failed cannot be announced as
    /// ready (L12), and a run that died reports the days it lost rather than
    /// nothing at all (L110).
    private func announce(landed: [DayName], failed: [DayName],
                          for eventID: UUID, appState: AppState) {
        guard let notice = LayoutSwitchNotice.of(landed: landed, failed: failed)
        else { return }
        // The live name, read after the writes: the run takes minutes and the
        // event may have been renamed while it ran.
        guard let name = appState.events.first(where: { $0.id == eventID })?.name
        else { return }
        if notice.isFailure {
            NotificationService.shared.notifyWorkFailed(
                work: "Layout switch", eventName: name, reason: notice.what)
        } else {
            NotificationService.shared.notifyRegenerationComplete(
                eventName: name, what: notice.what)
        }
    }

    /// Land one finished (or adopted) day render onto the live event: the new
    /// images, what the run said about the day, the clip plan and cover pick it
    /// came back with, the slot released, and the number the screen reloads on.
    ///
    /// Separate from the run that produced it so it can be tested: the run goes
    /// through `PythonBridge.shared`, which has no seam, and what a finished
    /// result MEANS is the half worth testing.
    ///
    /// Returns whether the day actually landed. A finished rebuild is announced
    /// from this answer, so a failure cannot be announced as ready.
    @discardableResult
    func applyDayRender(_ result: PythonBridge.PreviewGenerationResult,
                        day: DayName,
                        for eventID: UUID,
                        appState: AppState) -> Bool {
        // Live read at write-back: a render takes a minute or more, and a
        // snapshot taken when it started would revert anything edited since.
        guard var ev = appState.events.first(where: { $0.id == eventID }) else {
            // The event went away mid run. Release the slot rather than leaving
            // a spinner on a day nothing will ever finish (L110).
            endDayRegen(day, for: eventID)
            return false
        }

        // Keep the asset screen's failure list in step with what happened here,
        // so a day fixed (or broken again) from one screen does not leave a
        // contradictory message behind on the other. The recording is on the
        // model (#824), so the rule that a note is CLEARED when the next render
        // has nothing to say is one rule rather than one per screen. Recorded
        // alongside the error rather than folded into it: a day that rendered
        // without an optional photo is not a day with no graphics (#265).
        let noted = ev.recordMediaOutcome(day: day.rawValue,
                                          error: result.errors[day.rawValue],
                                          warning: result.warnings[day.rawValue])

        switch DayRedrawOutcome.of(result, day: day) {
        case .failed(let reason):
            if noted { appState.updateEvent(ev) }
            // The pipeline's own text where it had one, not a sentence wrapped
            // around it: the marker it uses for the cases that have a remedy
            // has to survive to the card that offers one (#730). The wording is
            // built by `failDayRegen`, which records it AND releases the slot.
            if let pipelineError = result.errors[day.rawValue] {
                failDayRegen(day, for: eventID, pipelineError: pipelineError)
            } else {
                failDayRegen(day, for: eventID, reason: reason)
            }
            return false
        case .succeeded(let dayPaths):
            ev.previewMediaPaths[day.rawValue] = dayPaths
            // What these images were drawn under, so a later switch can tell a
            // day it has moved past from one it never touched (#1010). Read
            // from the event being written, which is the same expression
            // `PythonBridge.buildMediaManifest` puts in the manifest, so the
            // record and the render cannot name different layouts.
            ev.recordRenderedLayout(ev.effectivePostingPreset, forDays: [day.rawValue])
            if day == .friday { ev.applyFridayClipPlan(result.fridayClipPlan) }
            ev.applyCoverPick(result.coverPicks[day.rawValue], forDay: day.rawValue)
            appState.updateEvent(ev)
            // Both after the write, so a screen redrawing on the new number
            // cannot read a half updated event.
            endDayRegen(day, for: eventID)
            bumpGraphicVersion(day, for: eventID)
            return true
        }
    }

    /// The day rebuild ended badly. Records why AND releases the slot, in one
    /// call, because a failure that forgot to release leaves that day unable to
    /// rebuild ever again, and the two were remembered separately at five call
    /// sites.
    func failDayRegen(_ day: DayName, for eventID: UUID, reason: String) {
        dayFailures[DaySlot(eventID: eventID, day: day)] =
            Recorded(reason: reason, pipelineError: nil)
        endDayRegen(day, for: eventID)
    }

    /// The same, for a rebuild the PIPELINE reported an error for (#730).
    ///
    /// Its own call rather than an optional argument on the one above. The
    /// pipeline's marker is the only thing the Friday card can decide from, and
    /// an argument that could be left out would be left out: a default standing
    /// for absent turns a forgotten value into silently missing data rather
    /// than a compile error (L168). Here the two callers mean different things,
    /// so they say different things.
    ///
    /// The sentence is built HERE rather than by the caller, so there is one
    /// wording for a pipeline failure and no way to record the wrapping without
    /// the marker it was wrapped around.
    func failDayRegen(_ day: DayName, for eventID: UUID, pipelineError: String) {
        dayFailures[DaySlot(eventID: eventID, day: day)] = Recorded(
            reason: Self.pipelineFailureSentence(day: day, error: pipelineError),
            pipelineError: pipelineError)
        endDayRegen(day, for: eventID)
    }

    /// What Dan reads when the pipeline reported an error for a day.
    static func pipelineFailureSentence(day: DayName, error: String) -> String {
        "\(day.displayName) regeneration failed: \(error)"
    }

    func failCoverRegen(_ day: DayName, for eventID: UUID, reason: String) {
        coverFailures[DaySlot(eventID: eventID, day: day)] = reason
        endCoverRegen(day, for: eventID)
    }

    func clearDayFailure(_ day: DayName, for eventID: UUID) {
        dayFailures.removeValue(forKey: DaySlot(eventID: eventID, day: day))
    }

    func clearCoverFailure(_ day: DayName, for eventID: UUID) {
        coverFailures.removeValue(forKey: DaySlot(eventID: eventID, day: day))
    }

    /// Every day of this event whose rebuild failed, in the week's own order.
    func dayFailures(for eventID: UUID) -> [DayFailure] {
        listedDays(for: eventID)
    }

    /// The same for the cover rebuilds, which are their own slot with their own
    /// remedy: rebuilding the reel is not rebuilding the thumbnail (L11).
    func coverFailures(for eventID: UUID) -> [DayFailure] {
        Self.listed(coverFailures, for: eventID)
    }

    private func listedDays(for eventID: UUID) -> [DayFailure] {
        DayName.allCases.compactMap { dayFailure($0, for: eventID) }
    }

    private static func listed(_ store: [DaySlot: String],
                               for eventID: UUID) -> [DayFailure] {
        DayName.allCases.compactMap { day in
            store[DaySlot(eventID: eventID, day: day)].map {
                DayFailure(day: day, reason: $0, pipelineError: nil)
            }
        }
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
