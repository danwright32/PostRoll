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

    enum Phase: Equatable {
        case exportingText
        case generatingMedia(URL)            // folder where text export landed
        /// Export finished. `mediaError` means the folder is missing
        /// something and the event is NOT archived; `mediaWarning` means an
        /// input was missing and the folder is complete anyway. Two fields
        /// because they need opposite responses (#265).
        case done(URL, mediaError: String?, mediaWarning: String?)
        case failed(String)
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

    private let tracker = EventJobTracker<Run>(elapsed: \.elapsedSeconds)

    func run(for id: Event.ID) -> Run? { tracker.job(for: id) }
    func isExporting(_ id: Event.ID) -> Bool { tracker.isActive(id) }

    /// The done screen is up and the media step is still running behind it.
    /// Distinct from `isExporting` so the sidebar can say what is actually
    /// happening without blocking Done (#182).
    func isFinishingMedia(_ id: Event.ID) -> Bool {
        tracker.job(for: id)?.finishingMedia == true
    }

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
        if let waiting = ExportReadiness.blockedReason(regeneratingDays: regeneratingDays) {
            tracker.begin(Run(phase: .failed(
                "\(waiting) before exporting, so the folder gets the new files rather than the previous ones."),
                              isFullExport: onlyDay == nil), for: eventID)
            tracker.deactivate(eventID)
            return
        }

        guard let ev = appState.events.first(where: { $0.id == eventID }) else { return }

        guard destinationRoot.startAccessingSecurityScopedResource() else {
            // A failed access isn't an active run; store it deactivated so the
            // view shows the error and `clear` can dismiss it.
            tracker.begin(Run(phase: .failed("Could not access the selected folder."),
                              isFullExport: onlyDay == nil), for: eventID)
            tracker.deactivate(eventID)
            return
        }

        UserDefaults.standard.set(destinationRoot.path, forKey: "lastExportFolder")

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
    #endif

    /// Dismiss a finished (done/failed) export so the screen returns to ready.
    /// Ignored while a run is still in flight.
    func clear(eventID: Event.ID) {
        guard !isExporting(eventID) else { return }
        tracker.remove(eventID)
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
        AccountBook.shared.noteTagged(handles: CaptionBlocks.accountsTagged(event: capturedEvent),
                                      on: exportedAt)
        // Copied once rather than reached into from the detached task below:
        // the book is main-actor state (#278).
        let accountStats = AccountBook.shared.snapshot()
        // An unreadable book looks exactly like an empty one from the export's
        // side: every account comes back not counted. Carried so CAPTIONS.txt
        // says which of the two it is.
        let accountNotes = AccountBook.shared.loadStatus == .unreadable
            ? [AccountBook.unreadableNote] : []

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
            let folder = textExport.folder
            // Files the export meant to copy and couldn't. Carried all the way
            // to the done screen: an export folder that is short a photo used
            // to report success and still stamp the event as Exported (#79).
            var droppedAssets = textExport.dropped

            tracker.update(eventID) {
                $0.phase = .generatingMedia(folder)
                $0.estimatedMediaSeconds = TimingStore.shared.mediaExportEstimate
            }

            // Step 2: copy assets from approved previews where possible; only
            // invoke Python for days whose preview files are missing or stale.
            let previewPaths = capturedEvent.previewMediaPaths
            let daysToProcess: [DayName] = onlyDay.map { [$0] } ?? DayName.allCases

            var daysNeedingPython: [String] = []
            var contentDayCount = 0
            // Held rather than reported straight away: the day these came from
            // falls through to Python, which may well produce the file anyway,
            // and a warning about a file that IS in the folder is its own defect.
            // Reconciled against the finished folder below (#357).
            var previewCopyFailures: [(asset: EventExporter.DroppedAsset, destination: URL)] = []
            /// Approved images that were not on disk to be put back over the
            /// regenerated ones, so the export used the machine's version (#377).
            var absentApprovals: [PreviewMergePolicy.AbsentApproval] = []

            for day in daysToProcess {
                let hasContent = (capturedEvent.weekResult?[day] != nil)
                    || (day == .friday && capturedEvent.days[day.rawValue] != nil)
                guard hasContent else { continue }
                contentDayCount += 1

                // Collage-carousel days (Wednesday always; Sunday/Monday under
                // the balanced preset): render directly from the live SwiftUI
                // overlay so crop offsets / cell-frame edits match what the user
                // saw on screen.
                if capturedEvent.effectivePostingPreset.isCollageCarousel(day),
                   (await renderCollage(day: day, event: capturedEvent, exportFolder: folder)) != nil {
                    continue
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
                        for (_, srcPath) in assets where srcPath.hasSuffix(".png") {
                            guard FileManager.default.fileExists(atPath: srcPath) else { continue }
                            let src = URL(fileURLWithPath: srcPath)
                            let dest = dayDir.appendingPathComponent(src.lastPathComponent)
                            try? FileManager.default.removeItem(at: dest)
                            do {
                                try FileManager.default.copyItem(at: src, to: dest)
                            } catch {
                                droppedAssets.append(EventExporter.DroppedAsset(
                                    label: "\(day.displayName) \(src.lastPathComponent)",
                                    source: src, reason: error.localizedDescription))
                            }
                        }
                    }
                } catch {
                    mediaError = error.localizedDescription
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
            let dropWarning = EventExporter.Outcome(folder: folder, dropped: droppedAssets).warning
            let combinedError = [mediaError, dropWarning].compactMap { $0 }.joined(separator: "\n\n")

            // A substitution goes in the WARNING slot, not the error one: the
            // folder is complete and usable, it just isn't carrying the version
            // Dan approved, which is his call to make rather than a failure.
            let substitution = PreviewMergePolicy.substitutionNotice(absentApprovals)
            let combinedWarning = [mediaWarning, substitution]
                .compactMap { $0 }.joined(separator: "\n\n")

            finishSuccess(eventID: eventID, folder: folder, onlyDay: onlyDay,
                          daysNeedingPython: daysNeedingPython,
                          mediaError: combinedError.isEmpty ? nil : combinedError,
                          mediaWarning: combinedWarning.isEmpty ? nil : combinedWarning,
                          appState: appState)
        } catch is CancellationError {
            // Cancelled (skipMedia handles its own terminal state).
        } catch {
            destinationRoot.stopAccessingSecurityScopedResource()
            tracker.update(eventID) {
                $0.task = nil
                $0.phase = .failed(error.localizedDescription)
            }
            tracker.deactivate(eventID)
        }
    }

    private func finishSuccess(eventID: Event.ID, folder: URL, onlyDay: DayName?,
                               daysNeedingPython: [String], mediaError: String?,
                               mediaWarning: String? = nil,
                               appState: AppState) {
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
                ExportManifest.write(
                    ExportManifest.build(folder: folder,
                                         preset: ev.effectivePostingPreset,
                                         event: ev.name),
                    to: folder)
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
    private func renderCollage(day: DayName, event: Event, exportFolder: URL) async -> URL? {
        guard let basePath = event.previewMediaPaths[day.rawValue]?["collage"]
        else { return nil }
        let baseURL = URL(fileURLWithPath: basePath)
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return nil }

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
        guard let cells else { return nil }

        let dayDir = exportFolder.appendingPathComponent(day.folderName)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let outputURL = dayDir.appendingPathComponent("collage.png")

        let ok = CollageRenderer.render(
            baseURL: baseURL,
            cells: cells,
            cropOffsets: pd?.collageCropOffsets ?? [:],
            outputURL: outputURL
        )
        return ok ? outputURL : nil
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
