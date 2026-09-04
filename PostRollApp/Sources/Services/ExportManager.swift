import Foundation
import AppKit

/// Owns the export pipeline (text export → asset copy/regen → milestone stamp)
/// at app scope, keyed by event id.
///
/// ExportView previously ran this in a fire-and-forget `Task` and kept the
/// progress in view `@State`. The work itself survived an event switch, but the
/// progress UI was lost on the view's `.id(event.id)` remount — returning showed
/// the "ready" screen with no indication an export was running, and nothing
/// stopped the user from kicking off a second one. Holding the run here keeps
/// the progress visible across switches, drives the sidebar "Exporting…" pill,
/// and guards against concurrent exports of the same event. Mirrors
/// [GenerationManager] and [OCRManager].
@MainActor
@Observable
final class ExportManager {

    /// Everything the automatic figures fetch has to say (#1004, #1277).
    ///
    /// Handed in rather than read from the manager, because the export copies
    /// everything it needs before detaching and this is one more of those. Its
    /// OWN property rather than folded into the book's recovery note: two
    /// independent conditions sharing one field means one silences the other
    /// (L53).
    ///
    /// A list because the manager has more than one thing to say and they are
    /// independent: whether the last fetch failed, and whether the archive has
    /// ever been counted at all. Carried as the manager's own list rather than
    /// as a field per note, so a note added there cannot be dropped here (L41).
    var accountNumbersNotes: [String] = []


    enum Phase: Equatable {
        case exportingText
        case generatingMedia(URL)            // folder where text export landed
        /// Export finished. `mediaError` means the folder is missing
        /// something and the event is NOT archived; `mediaWarning` means an
        /// input was missing and the folder is complete anyway. Two fields
        /// because they need opposite responses (#265).
        case done(URL, mediaError: String?, mediaWarning: String?)
        case failed(String)
        /// Cancel has been accepted and the work is winding down (#1047).
        ///
        /// Its own phase rather than a flag beside `generatingMedia`, and it
        /// is deliberately not the same as stopped: the subprocess takes a
        /// moment to die, and a screen that jumps straight from running to
        /// gone claims something that has not happened yet. Three states have
        /// to be tellable apart while a cancel is in flight, which is the same
        /// rule every other long action here follows.
        case cancelling
        /// The run was abandoned. Nothing was committed and nothing is
        /// stamped: this is not a failure and not an export.
        case cancelled
    }

    struct Run {
        var phase: Phase
        var elapsedSeconds: Int = 0
        var estimatedMediaSeconds: Double?
        /// True for a full export (not a single-day re-export); only a full run
        /// stamps the archived milestone and feeds the timing mean.
        var isFullExport: Bool
        /// The done screen is showing while assets are still being written
        /// ("Skip, text export only"). Its own flag rather than a reuse of the
        /// active set, which also decided whether Done could dismiss the run
        /// and what the sidebar said (#182).
        var finishingMedia: Bool = false
        fileprivate var task: Task<Void, Never>?
    }

    private let tracker = JobTracker<Event.ID, Run>(elapsed: \.elapsedSeconds, task: \.task)

    func run(for id: Event.ID) -> Run? { tracker.job(for: id) }
    func isExporting(_ id: Event.ID) -> Bool { tracker.isActive(id) }

    /// Whether anything at all is exporting, asked before the app updates
    /// itself: installing quits PostRoll (#686).
    var hasWorkInFlight: Bool { tracker.hasWorkInFlight }

    /// The done screen is up and the media step is still running behind it.
    /// Distinct from `isExporting` so the sidebar can say what is actually
    /// happening without blocking Done (#182).
    func isFinishingMedia(_ id: Event.ID) -> Bool {
        tracker.job(for: id)?.finishingMedia == true
    }

    /// A cancel has been accepted and the work has not stopped yet (#1047).
    ///
    /// The tracker's own answer: a stop was asked for AND the run is still in
    /// flight. Asked that way rather than of the request alone, because the
    /// request stays recorded through a late cancel that the commit beat, and
    /// the sidebar must not go on saying "Cancelling…" over a finished export
    /// (L144). One record answering both questions, rather than a flag beside
    /// it that can disagree (#1050, L53).
    func isCancelling(_ id: Event.ID) -> Bool { tracker.isStopping(id) }

    /// Kick off an export. No-op if one is already running for this event, so a
    /// double-click or a view remount can't launch a second concurrent export.
    ///
    /// `regeneratingDays` has no default on purpose. Every route into an export
    /// has to state what is rebuilding, because the defect in #225 was exactly
    /// a route that never asked: a caller that could omit the argument would
    /// ship the stale copy again, and the omission would look like ordinary
    /// code (L72: the default must be the safe state, so there isn't one).
    func start(eventID: Event.ID, to destinationRoot: URL, onlyDay: DayName? = nil,
               appState: AppState, regeneratingDays: Set<DayName>) {
        guard !isExporting(eventID) else { return }

        // Refuse while any day is still rebuilding: the asset copy step would
        // take the previous mp4 or collage, because the new one lands in
        // previews after the export has already read them (#225). Recorded as a
        // visible failure rather than a silent return, using the same
        // deactivated-run shape as the folder-access refusal below, so the
        // button says what it is waiting for instead of doing nothing (#182).
        // The event is read BEFORE the gate rather than after it, because half
        // of what the gate asks is about the event itself: whether any day's
        // images are still drawn for the layout this event has moved away from
        // (#1010).
        guard let gated = appState.events.first(where: { $0.id == eventID }) else { return }
        if let waiting = ExportReadiness.blockedReason(
            for: gated, preset: gated.effectivePostingPreset,
            regeneratingDays: regeneratingDays) {
            let blocked = "\(waiting) before exporting, so the folder gets the new files rather than the previous ones."
            tracker.begin(Run(phase: .failed(blocked),
                              isFullExport: onlyDay == nil), for: eventID)
            tracker.deactivate(eventID)
            // Reached only from a button press, so `notifyWorkFailed` sees an
            // active app and stays quiet. It is here anyway rather than being
            // exempted: an exemption is a hand-kept list, and the entries
            // anybody remembers to add are the ones already safe (L96).
            NotificationService.shared.notifyWorkFailed(
                work: "exporting", eventName: "An event", reason: blocked)
            return
        }

        guard let ev = appState.events.first(where: { $0.id == eventID }) else { return }

        guard destinationRoot.startAccessingSecurityScopedResource() else {
            // A failed access isn't an active run; store it deactivated so the
            // view shows the error and `clear` can dismiss it.
            tracker.begin(Run(phase: .failed("Could not access the selected folder."),
                              isFullExport: onlyDay == nil), for: eventID)
            tracker.deactivate(eventID)
            // As above: a click reaches this, so it stays quiet in practice.
            NotificationService.shared.notifyWorkFailed(
                work: "exporting", eventName: ev.name,
                reason: "Could not access the selected folder.")
            return
        }

        // The folder is NOT remembered app wide (#1048). It is recorded on the
        // event itself, below, by the run that finishes, and `ExportFolderStatus
        // .rememberedFolder` is what reads it back. One shared key put the
        // previous show's folder on a new show's screen as its fastest button.

        tracker.begin(Run(phase: .exportingText, isFullExport: onlyDay == nil), for: eventID)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runExport(eventID: eventID, snapshot: ev,
                                 destinationRoot: destinationRoot, onlyDay: onlyDay,
                                 appState: appState)
        }
        tracker.update(eventID) { $0.task = task }
    }

    #if POSTROLL_TESTS
    /// Test seam: put an event into a given phase without running the pipeline.
    ///
    /// Compiled only into the test bundle. Driving these transitions by calling
    /// `start` and waiting means racing the real export, which writes files and
    /// shells out to Python, and a test that has to sleep to be right is a test
    /// that will be flaky later.
    func setRunForTesting(phase: Phase, isFullExport: Bool = true,
                          for id: Event.ID) {
        tracker.begin(Run(phase: phase, isFullExport: isFullExport), for: id)
    }

    /// Test seam: mark a run no longer in flight, as the pipeline does when it
    /// reaches a terminal phase.
    func deactivateForTesting(_ id: Event.ID) {
        tracker.deactivate(id)
    }

    /// Test seam: hang a real task off the run, as `start` does.
    ///
    /// Without it, `cancel` can be shown to change the PHASE and nothing shows
    /// that it reaches the work. The phase is the cheap half; the reason a
    /// cancel exists at all is that the subprocess dies, and a screen saying
    /// "Cancelling…" over an ffmpeg still burning the machine would be worse
    /// than the button not being there (#1047, L3).
    func setTaskForTesting(_ task: Task<Void, Never>, for id: Event.ID) {
        tracker.update(id) { $0.task = task }
    }
    #endif

    /// Dismiss a finished (done/failed) export so the screen returns to ready.
    /// Ignored while a run is still in flight.
    func clear(eventID: Event.ID) {
        guard !isExporting(eventID) else { return }
        tracker.remove(eventID)
    }

    /// Abandon the run (#1047).
    ///
    /// NOT "Skip, text export only", which is the opposite instruction: skip
    /// means finish the export with less in it, and it deliberately leaves the
    /// media step running so the milestone still gets stamped. Cancel means
    /// Dan did not want this export at all, most often because it is the wrong
    /// show, the wrong photos or the wrong preset, and until this existed the
    /// only ways out of a three minute run were to wait for work that was
    /// going to be thrown away or to quit the app.
    ///
    /// Returns whether the request was taken, so a caller can tell a cancel
    /// from a press that arrived after the run was already over rather than
    /// having to re-read the phase and guess (L197).
    ///
    /// The task is cancelled, which is what actually stops the work:
    /// `ProcessRunner` SIGTERMs the whole subprocess tree and SIGKILLs
    /// whatever survives the grace period, so ffmpeg and Python die with the
    /// run rather than being orphaned onto a machine the next run has to
    /// compete with. Nothing is committed, because every step writes into the
    /// staging folder and only a finished run swaps it in (#442), so the
    /// previous export is still where it was.
    ///
    /// The run stays ACTIVE while it winds down. Deactivating here would let a
    /// second export start against a folder the dying one is still writing.
    @discardableResult
    func cancel(eventID: Event.ID) -> Bool {
        guard let run = tracker.job(for: eventID), isExporting(eventID) else { return false }
        switch run.phase {
        case .exportingText, .generatingMedia:
            break
        case .cancelling, .cancelled, .done, .failed:
            // A second press, or one that landed on a run already over. Both
            // are no-ops, and saying so is the point: pressing twice must not
            // do anything a single press did not (#1047).
            return false
        }
        tracker.update(eventID) { $0.phase = .cancelling }
        // The tracker cancels the task and remembers the request. It is the
        // one implementation of stopping (#1050), and `cancelRequested` used
        // to be a second record of the same fact beside it (L53).
        return tracker.requestStop(eventID)
    }

    /// User chose "Skip, text export only" — show the done screen now without
    /// waiting for media. The underlying run keeps finishing media in the
    /// background and stamps the milestone when it completes (matching the
    /// original screen's behavior); cancelling here would race the completion
    /// handler and could drop the "Exported" stamp.
    func skipMedia(eventID: Event.ID) {
        guard let run = tracker.job(for: eventID), case .generatingMedia(let folder) = run.phase else { return }
        tracker.update(eventID) {
            $0.phase = .done(folder, mediaError: nil, mediaWarning: nil)
            $0.finishingMedia = true
        }
        // Deactivated so the sidebar stops claiming "Exporting…" while the
        // pane says complete, and so Done can dismiss the run. The underlying
        // task is NOT cancelled: it keeps finishing media and still stamps the
        // milestone, which is the whole point of this button (#182).
        tracker.deactivate(eventID)
    }

    // MARK: - Pipeline

    private func runExport(eventID: Event.ID, snapshot capturedEvent: Event,
                           destinationRoot: URL, onlyDay: DayName?, appState: AppState) async {
        let scopedDays: Set<DayName>? = onlyDay.map { [$0] }

        // Every account this week tags is remembered, so the book doubles as a
        // browsable list of everyone ever tagged and a performer shot in March
        // is already there the next time they turn up (#279). Numbers are never
        // invented here: an account seen but not counted stays uncounted.
        //
        // accountsTagged rather than the caption's own tag list, because the org
        // and venue handles reach every post by a separate route and were the
        // only accounts the book could never remember (#289). They are also the
        // only ones that recur: measured on the 19 events on disk, all 6
        // returning accounts are venue or org handles, so the book was keeping
        // exactly the one-offs and missing everyone who comes back.
        let exportedAt = Date()
        // Worked out now, because it reads the event as it stands at the start
        // of the run, and WRITTEN only once the export has committed (#483).
        //
        // The book used to be stamped here. A failed export never rolled it
        // back, so the book recorded tags that never shipped, and the
        // recurring-account freshness stats it feeds were reading from a
        // non-event. Record intent, confirm after the effect verifiably
        // happened (L33), and here the confirmation IS the record.
        let tagStamp = ExportTagStamp(
            handles: CaptionBlocks.accountsTagged(event: capturedEvent), at: exportedAt)
        // Copied once rather than reached into from the detached task below:
        // the book is main-actor state (#278).
        let accountStats = AccountBook.shared.snapshot()
        // An unreadable book looks exactly like an empty one from the export's
        // side: every account comes back not counted. Carried so CAPTIONS.txt
        // says which of the two it is.
        // Both notes, as two elements (#1004). The export runs detached, so
        // this is copied with everything else rather than reached for from the
        // task below. Set by the app when the fetch manager exists; nil in the
        // suite, which is the same as no failure to report.
        let accountNotes = [AccountBook.shared.recoveryNote].compactMap { $0 }
                         + accountNumbersNotes

        // Held outside the do so the failure paths can throw the staged work
        // away: a staging folder nobody commits is debris in Dan's own folder.
        var staging: ExportStaging?

        do {
            // Step 1: text export (fast, on background thread). The security
            // scope is released once the synchronous export returns.
            let textExport = try await Task.detached {
                defer { destinationRoot.stopAccessingSecurityScopedResource() }
                return try EventExporter.export(event: capturedEvent, to: destinationRoot, days: scopedDays,
                                                preset: capturedEvent.effectivePostingPreset,
                                                collaboratorStats: { accountStats[AccountBook.key($0)] },
                                                asOf: exportedAt,
                                                collaboratorNotes: accountNotes)
            }.value
            // Every step below writes into the STAGING folder; `destination`
            // is where it all lands when the run finishes (#442). Anything
            // shown to Dan or stored on the event uses the destination, because
            // the staging path exists only while the run does.
            let folder = textExport.folder
            let destination = textExport.destination
            staging = textExport.staging
            // Files the export meant to copy and couldn't. Carried all the way
            // to the done screen: an export folder that is short a photo used
            // to report success and still stamp the event as Exported (#79).
            var droppedAssets = textExport.dropped

            tracker.update(eventID) {
                $0.phase = .generatingMedia(destination)
                $0.estimatedMediaSeconds = TimingStore.shared.mediaExportEstimate
            }

            // Step 2: copy assets from approved previews where possible; only
            // invoke Python for days whose preview files are missing or stale.
            let previewPaths = capturedEvent.previewMediaPaths
            let daysToProcess: [DayName] = onlyDay.map { [$0] } ?? DayName.allCases

            var daysNeedingPython: [String] = []
            var contentDayCount = 0
            /// The days this run actually wrote, collected where the run
            /// decides it rather than recomputed afterwards from the event: a
            /// second derivation of "which days did we export" would drift from
            /// this loop silently, and a single day re-export must not leave a
            /// claim about the rest of the week (L263, L166).
            var daysExported: [DayName] = []
            // Held rather than reported straight away: the day these came from
            // falls through to Python, which may well produce the file anyway,
            // and a warning about a file that IS in the folder is its own defect.
            // Reconciled against the finished folder below (#357).
            var previewCopyFailures: [(asset: EventExporter.DroppedAsset, destination: URL)] = []
            /// Approved images that were not on disk to be put back over the
            /// regenerated ones, so the export used the machine's version (#377).
            var absentApprovals: [PreviewMergePolicy.AbsentApproval] = []
            /// Days whose collage was there but could not carry Dan's edits
            /// into the export (#447).
            var collageBakeFailures: [(day: String, reason: CollageBakeOutcome.Reason)] = []

            for day in daysToProcess {
                // A cancel between days takes effect here (#1047). Without it
                // the only checkpoint is inside a Python run, so a cancel
                // pressed during the copy-only fast path would be honoured
                // only once the whole week had been copied, which is the
                // commonest export there is.
                try Task.checkCancellation()
                let hasContent = (capturedEvent.weekResult?[day] != nil)
                    || (day == .friday && capturedEvent.days[day.rawValue] != nil)
                guard hasContent else { continue }
                contentDayCount += 1
                daysExported.append(day)

                // Collage-carousel days (Wednesday always; Sunday/Monday under
                // the balanced preset): render directly from the live SwiftUI
                // overlay so crop offsets / cell-frame edits match what the user
                // saw on screen.
                if capturedEvent.effectivePostingPreset.isCollageCarousel(day) {
                    switch await renderCollage(day: day, event: capturedEvent, exportFolder: folder) {
                    case .baked:
                        continue
                    case .couldNotApplyEdits(let reason):
                        // Held rather than thrown: the day still falls through
                        // to the copy and the Python regen, so the folder ends
                        // up complete. What it will NOT carry is Dan's crop
                        // offsets and cell edits, and that has to be said out
                        // loud or the export finishes clean carrying an image
                        // he did not approve (#447).
                        collageBakeFailures.append((day: day.displayName, reason: reason))
                    case .nothingToBake:
                        break
                    }
                }

                // Thursday reel renders a live overlay on saved frames; if the user
                // has crop offsets, force a Python regen so they bake in.
                let hasUnflattenedEdits: Bool = {
                    guard let pd = capturedEvent.days[day.rawValue] else { return false }
                    if day == .thursday { return !pd.reelCropOffsets.isEmpty }
                    return false
                }()

                // A copy that failed is not a day that is done (#357). It falls
                // through to Python like any other incomplete day, and the
                // failures are held so they can be reported if Python does not
                // rescue them either.
                let dayFolder = folder.appendingPathComponent(day.folderName)
                let fastCopy = hasUnflattenedEdits
                    ? PreviewMergePolicy.PreviewCopyResult.declined
                    : PreviewMergePolicy.copyPreviewAssetsIfComplete(
                        assets: previewPaths[day.rawValue],
                        to: dayFolder,
                        label: day.displayName
                      )
                previewCopyFailures.append(contentsOf: fastCopy.dropped.map {
                    ($0, dayFolder.appendingPathComponent($0.source.lastPathComponent))
                })

                if fastCopy.satisfied {
                    // Every preview file existed and landed, no Python needed.
                } else {
                    daysNeedingPython.append(day.rawValue)
                }
            }

            // Refine the estimate now that we know which days copy (fast) vs
            // regenerate via Python (slow).
            let refinedEstimate: Double = {
                if daysNeedingPython.isEmpty, let learned = TimingStore.shared.mediaExportEstimate {
                    return learned
                }
                return Self.estimateMediaSeconds(pythonDays: daysNeedingPython, contentDayCount: contentDayCount)
            }()
            tracker.update(eventID) { $0.estimatedMediaSeconds = refinedEstimate }

            var mediaError: String? = nil
            var mediaWarning: String? = nil
            if !daysNeedingPython.isEmpty {
                // Run Python only for the days without complete previews.
                do {
                    let media = try await PythonBridge.shared.runMediaGeneration(
                        event: capturedEvent,
                        outputDir: folder.deletingLastPathComponent(),
                        days: daysNeedingPython
                    )
                    // Per-day failures were dropped here while the preview path
                    // read the same field, so an export could finish "clean"
                    // with a day's asset quietly missing from the folder (#262).
                    // A zero exit is not a promise every day rendered.
                    //
                    // Every entry in `errors` is a failure now. It used to also
                    // carry notes about days that rendered fine with an optional
                    // input missing, which had to be guessed apart by checking
                    // whether the day produced any files; Python separates them
                    // at the source (#265), so a warning blocks nothing and is
                    // still said out loud.
                    mediaError = MediaErrorSummary.sentence(media.errors)
                    mediaWarning = MediaErrorSummary.warningSentence(media.warnings)
                    // For the Python-regenerated days, overwrite fresh PNGs with any
                    // approved previews that do exist (partial-preview edge case).
                    for day in daysToProcess where daysNeedingPython.contains(day.rawValue) {
                        guard let assets = previewPaths[day.rawValue] else { continue }
                        let dayDir = folder.appendingPathComponent(day.folderName)
                        // An approval that is not on disk cannot be put back, and
                        // the day then ships the machine's version of an image Dan
                        // approved his own edit of. The folder is not short a file,
                        // so this is not a dropped asset: it is a substitution, and
                        // it has to be said out loud rather than skipped (#377).
                        absentApprovals.append(contentsOf: PreviewMergePolicy.absentApprovals(
                            assets: assets, label: day.displayName))
                        // Every approved asset, not only the PNGs. The reel is an
                        // mp4 and is one of the things Dan approves, so restoring
                        // images alone shipped the machine's reel on any day that
                        // was regenerated (#383).
                        droppedAssets.append(contentsOf: PreviewMergePolicy.restoreAvailableApprovals(
                            assets: assets, to: dayDir, label: day.displayName))
                    }
                } catch {
                    mediaError = ((error as? PythonBridgeError)?.message(whileDoing: .export) ?? error.localizedDescription)
                }
            }

            // A preview that would not copy is only worth reporting if it is
            // still absent once Python has had its turn. Judged from the
            // finished folder rather than from either code path, so a file put
            // there by the regen is not reported missing (#357).
            droppedAssets.append(contentsOf: previewCopyFailures
                .filter { !FileManager.default.fileExists(atPath: $0.destination.path) }
                .map(\.asset))

            // The dropped-asset warning shares the done screen's error slot with
            // the Python error: both mean the folder isn't what it claims.
            let dropWarning = EventExporter.warning(for: droppedAssets)
            let combinedError = [mediaError, dropWarning].compactMap { $0 }.joined(separator: "\n\n")

            // A substitution goes in the WARNING slot, not the error one: the
            // folder is complete and usable, it just isn't carrying the version
            // Dan approved, which is his call to make rather than a failure.
            let substitution = PreviewMergePolicy.substitutionNotice(absentApprovals)
            // Same slot and the same reason: the folder is complete, it is just
            // not carrying the version Dan adjusted (#447).
            let collageNotice = CollageBakeNotice.sentence(collageBakeFailures)
            let combinedWarning = [mediaWarning, substitution, collageNotice]
                .compactMap { $0 }.joined(separator: "\n\n")

            // The run is over, so the staged export replaces the previous one
            // now (#442). Until this line the previous export is untouched and
            // complete, which is the whole point: a text write that throws, a
            // Python step that dies or a disk that fills leaves Dan with the
            // last export he could actually upload.
            // The last moment a cancel can still mean "this export does not
            // happen" (#1047). Past the commit the folder Dan uploads from has
            // already been replaced, so a cancel arriving later cannot undo it
            // and must not pretend to: the run finishes and the done screen
            // says the press came too late. Checked immediately before the
            // swap rather than earlier, because everything between the two
            // would otherwise be a window where the button silently did
            // nothing (L157).
            try Task.checkCancellation()

            var swapError: String? = nil
            do {
                try textExport.staging.commit()
            } catch let failure as ExportStaging.SwapFailure {
                // The work was done and is sitting somewhere; saying "export
                // failed" without naming that folder loses all of it (L11).
                swapError = "The export could not be moved into "
                    + "\(destination.lastPathComponent): \(Sentence.closed(failure.reason)) "
                    + "It is complete and waiting at \(failure.stagedAt.path), and the "
                    + "previous export is still in place."
            } catch {
                swapError = Sentence.closed(((error as? PythonBridgeError)?.message(whileDoing: .export) ?? error.localizedDescription))
            }
            let errorWithSwap = [combinedError.isEmpty ? nil : combinedError, swapError]
                .compactMap { $0 }.joined(separator: "\n\n")

            // A cancel that arrived AFTER the export had been written. Read
            // here rather than before the commit check above, because before
            // it a request throws instead and this line is never reached: read
            // early it could only ever be false, and the button Dan pushed
            // would vanish without a word (#1047, L11).
            //
            // The run genuinely succeeded, so this is a warning and not an
            // error: the folder is complete and the milestone is honestly
            // stamped. What it must not do is report an ordinary success and
            // leave him assuming the cancel worked.
            let lateCancel = tracker.wasStopRequested(eventID)
                ? "Cancel arrived after the export had already been written, so "
                  + "it went ahead and the folder is complete. Delete it if you "
                  + "did not want it."
                : nil
            let warningWithCancel = [combinedWarning.isEmpty ? nil : combinedWarning,
                                     lateCancel]
                .compactMap { $0 }.joined(separator: "\n\n")

            finishSuccess(eventID: eventID, folder: destination, onlyDay: onlyDay,
                          daysNeedingPython: daysNeedingPython,
                          daysExported: daysExported,
                          mediaError: errorWithSwap.isEmpty ? nil : errorWithSwap,
                          mediaWarning: warningWithCancel.isEmpty ? nil : warningWithCancel,
                          tagStamp: tagStamp,
                          appState: appState)
        } catch is CancellationError {
            // Cancelled (skipMedia handles its own terminal state).
            //
            // The staged work goes, so nothing half written is left looking
            // like an export and the previous one is untouched (#442).
            staging?.abandon()
            finishCancelled(eventID: eventID)
        } catch {
            staging?.abandon()
            destinationRoot.stopAccessingSecurityScopedResource()
            let reason = ((error as? PythonBridgeError)?.message(whileDoing: .export) ?? error.localizedDescription)
            tracker.update(eventID) {
                $0.task = nil
                $0.phase = .failed(reason)
            }
            tracker.deactivate(eventID)
            // Said out loud when he is not looking (#872). An export is the
            // longest thing this app does, and it was the one kind of work that
            // still died in silence: it records a failure by setting a phase
            // rather than through `markFailed`, so the sweep that holds every
            // other failure path to announcing could not see it at all.
            NotificationService.shared.notifyWorkFailed(
                work: "exporting",
                eventName: capturedEvent.name,
                reason: reason)
        }
    }

    /// The run stopped because it was cancelled (#1047).
    ///
    /// Its own method rather than a block inside the catch so it can be driven
    /// by a test: the catch itself is only reachable by running a real export,
    /// so leaving the whole terminal transition in there would mean the phase a
    /// cancel actually lands in was never exercised (L3).
    ///
    /// A terminal phase and a deactivation, both of which were missing while
    /// nothing could reach that branch: without them a cancelled run stayed in
    /// `generatingMedia` forever, `isExporting` stayed true, and the screen
    /// went on showing a spinner for work that had already stopped (L110).
    ///
    /// Deliberately NO failure notification, and no `markFailed`. Dan pressed
    /// the button; telling him his export failed would be a claim about
    /// something that did not happen (L11).
    func finishCancelled(eventID: Event.ID) {
        tracker.update(eventID) {
            $0.task = nil
            $0.phase = .cancelled
            // The media step is over too, so the sidebar does not go on
            // claiming assets are still being written behind a stopped run
            // (#182).
            $0.finishingMedia = false
        }
        tracker.deactivate(eventID)
    }

    private func finishSuccess(eventID: Event.ID, folder: URL, onlyDay: DayName?,
                               daysNeedingPython: [String],
                               daysExported: [DayName] = [], mediaError: String?,
                               mediaWarning: String? = nil,
                               tagStamp: ExportTagStamp? = nil,
                               appState: AppState) {
        // The export committed, so the tags genuinely shipped and the book can
        // say so (#483). A run that died before here never applies its stamp.
        tagStamp?.apply(to: AccountBook.shared)
        // Only learn from full copy-only runs so the mean stays a clean signal
        // for the common fast path.
        if onlyDay == nil && daysNeedingPython.isEmpty {
            TimingStore.shared.recordMediaExport(seconds: Double(tracker.job(for: eventID)?.elapsedSeconds ?? 0))
        }

        tracker.update(eventID) {
            $0.task = nil
            $0.phase = .done(folder, mediaError: mediaError, mediaWarning: mediaWarning)
            // The media step is genuinely over now, whether or not Skip was
            // pressed earlier, so the sidebar stops saying assets are still
            // being written (#182).
            $0.finishingMedia = false
        }
        tracker.deactivate(eventID)

        // A full export is the real "Exported" milestone: stamp the live event
        // so the sidebar pill stops reading "Ready to Export" and the archive
        // clock starts from actual completion. Single-day re-exports don't.
        // The archive clock starts the 60-day countdown that reclaims this
        // event's photos, so it is only stamped on an export that is actually
        // complete. An export missing files, or one whose assets failed to
        // render, is not that milestone (#79); the folder still exists and its
        // path is recorded so it can be opened and re-exported once whatever
        // went wrong is fixed.
        if onlyDay == nil, var ev = appState.events.first(where: { $0.id == eventID }) {
            ev.exportPath = folder
            if mediaError == nil { ev.archivedAt = Date() }
            appState.updateEvent(ev)

            // Written LAST, and only on a full run that lost nothing, because
            // its presence is what tells a later reader the folder is finished
            // (#184). A run that was interrupted, or one missing files, leaves
            // no manifest, which is the honest state.
            if mediaError == nil {
                let contents = ExportManifest.build(folder: folder,
                                                    preset: ev.effectivePostingPreset,
                                                    event: ev.name)
                // The answer is not discarded. Its absence is what every later
                // reader uses to conclude the export never finished, so a write
                // that failed leaves a good export bannered forever as one that
                // did not happen, with advice to run it again and nothing
                // saying it was the record rather than the export that failed
                // (#452).
                let extra: String?
                if ExportManifest.write(contents, to: folder) {
                    extra = ExportManifest.unreadableNotice(contents)
                } else {
                    extra = ExportManifest.writeFailureNotice
                }

                // Each exported day records, in its own PREVIEW folder, that
                // it was exported (#925). That folder is the one the design sweep
                // already walks and the one nothing moves; the manifest above
                // is a per day fact too, but it lives inside the export folder,
                // and every export folder on Dan's Mac has since been filed
                // somewhere else, so a sweep reading it would find nothing
                // exported forever.
                //
                // Written on the same condition as the manifest and the archive
                // stamp: only a full run that lost nothing is the milestone
                // this record claims.
                let unrecorded = DayExportRecord.stamp(days: daysExported, in: ev,
                                                       at: Date())
                if !unrecorded.isEmpty {
                    NSLog("DayExportRecord could not record: "
                          + unrecorded.map(\.rawValue).joined(separator: ", "))
                }

                let notices = [extra, DayExportRecord.recordFailureNotice(unrecorded)]
                    .compactMap { $0 }
                if !notices.isEmpty {
                    let combined = ([mediaWarning] + notices).compactMap { $0 }
                        .joined(separator: "\n\n")
                    tracker.update(eventID) {
                        $0.phase = .done(folder, mediaError: nil, mediaWarning: combined)
                    }
                }
            }
        }
        NotificationService.shared.notifyExportComplete(
            eventName: appState.events.first(where: { $0.id == eventID })?.name ?? "")
    }

    /// Render a day's collage from the live SwiftUI overlay so crop offsets and
    /// cell-frame edits match what the user saw. Works for any collage-carousel
    /// day (Wednesday always; Sunday/Monday under the balanced preset). Returns
    /// the output URL on success, nil if any precondition is missing.
    @MainActor
    private func renderCollage(day: DayName, event: Event,
                               exportFolder: URL) async -> CollageBakeOutcome {
        guard let basePath = event.previewMediaPaths[day.rawValue]?["collage"]
        else { return .nothingToBake }
        let baseURL = URL(fileURLWithPath: basePath)
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return .nothingToBake }

        let pd = event.days[day.rawValue]
        // Both sources are reconciled against the day's current photos: a layout
        // made for a different photo set would render cells from missing files,
        // which CollageRenderer skips silently, leaving holes in the export.
        let photos = pd?.photoPaths ?? []
        let cells: [CollageCell]? = {
            if let override = CollageCell.usable(pd?.collageCellOverride, forPhotos: photos) { return override }
            let decoded = LayoutSidecar.read(forPreview: baseURL).cells
            guard !decoded.isEmpty else { return nil }
            return CollageCell.usable(decoded, forPhotos: photos)
        }()
        guard let cells else { return .couldNotApplyEdits(.layoutDoesNotMatchThePhotos) }

        let dayDir = exportFolder.appendingPathComponent(day.folderName)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let outputURL = dayDir.appendingPathComponent("collage.png")

        let ok = CollageRenderer.render(
            baseURL: baseURL,
            cells: cells,
            cropOffsets: pd?.collageCropOffsets ?? [:],
            outputURL: outputURL
        )
        return ok ? .baked(outputURL) : .couldNotApplyEdits(.renderFailed)
    }

    /// Rough estimate for the visual asset run. Days copied from approved
    /// previews are near-instant; days that fall through to Python regen cost
    /// real time, dominated by reel encoding.
    static func estimateMediaSeconds(pythonDays: [String], contentDayCount: Int) -> Double {
        let copiedDays = max(0, contentDayCount - pythonDays.count)
        var total = Double(copiedDays) * 2.5   // file copies + Wednesday live render
        for key in pythonDays {
            switch DayName(rawValue: key) {
            case .tuesday, .thursday, .friday:
                total += 150   // reels / before-after video are the slow path
            default:
                total += 18    // story image regen
            }
        }
        return max(total, 6)
    }
}

/// Asked whenever PostRoll is about to quit or install an update (#862).
///
/// The phrase is a clause rather than a name, because it is dropped into a
/// sentence that already says what is happening to it.
extension ExportManager: BackgroundWork {
    var workPhrase: String { "an export is still running" }
}
