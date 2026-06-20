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
        case done(URL, mediaError: String?)  // export finished (asset gen may have warned)
        case failed(String)
    }

    struct Run {
        var phase: Phase
        var elapsedSeconds: Int = 0
        var estimatedMediaSeconds: Double?
        /// True for a full export (not a single-day re-export); only a full run
        /// stamps the archived milestone and feeds the timing mean.
        var isFullExport: Bool
        fileprivate var task: Task<Void, Never>?
    }

    private let tracker = EventJobTracker<Run>(elapsed: \.elapsedSeconds)

    func run(for id: Event.ID) -> Run? { tracker.job(for: id) }
    func isExporting(_ id: Event.ID) -> Bool { tracker.isActive(id) }

    /// Kick off an export. No-op if one is already running for this event, so a
    /// double-click or a view remount can't launch a second concurrent export.
    func start(eventID: Event.ID, to destinationRoot: URL, onlyDay: DayName? = nil, appState: AppState) {
        guard !isExporting(eventID) else { return }
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
        tracker.update(eventID) { $0.phase = .done(folder, mediaError: nil) }
    }

    // MARK: - Pipeline

    private func runExport(eventID: Event.ID, snapshot capturedEvent: Event,
                           destinationRoot: URL, onlyDay: DayName?, appState: AppState) async {
        let scopedDays: Set<DayName>? = onlyDay.map { [$0] }

        do {
            // Step 1: text export (fast, on background thread). The security
            // scope is released once the synchronous export returns.
            let folder = try await Task.detached {
                defer { destinationRoot.stopAccessingSecurityScopedResource() }
                return try EventExporter.export(event: capturedEvent, to: destinationRoot, days: scopedDays,
                                                preset: PostingPreset.current)
            }.value

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

            for day in daysToProcess {
                let hasContent = (capturedEvent.weekResult?[day] != nil)
                    || (day == .friday && capturedEvent.days[day.rawValue] != nil)
                guard hasContent else { continue }
                contentDayCount += 1

                // Collage-carousel days (Wednesday always; Sunday/Monday under
                // the balanced preset): render directly from the live SwiftUI
                // overlay so crop offsets / cell-frame edits match what the user
                // saw on screen.
                if PostingPreset.current.isCollageCarousel(day),
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

                if !hasUnflattenedEdits,
                   let assets = previewPaths[day.rawValue],
                   !assets.isEmpty,
                   assets.values.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                    // All preview files exist — copy directly, no Python needed.
                    let dayDir = folder.appendingPathComponent(day.folderName)
                    try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
                    for (_, srcPath) in assets {
                        let src = URL(fileURLWithPath: srcPath)
                        let dest = dayDir.appendingPathComponent(src.lastPathComponent)
                        try? FileManager.default.removeItem(at: dest)
                        _ = try? FileManager.default.copyItem(at: src, to: dest)
                    }
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
            if !daysNeedingPython.isEmpty {
                // Run Python only for the days without complete previews.
                do {
                    _ = try await PythonBridge.shared.runMediaGeneration(
                        event: capturedEvent,
                        outputDir: folder.deletingLastPathComponent(),
                        days: daysNeedingPython
                    )
                    // For the Python-regenerated days, overwrite fresh PNGs with any
                    // approved previews that do exist (partial-preview edge case).
                    for day in daysToProcess where daysNeedingPython.contains(day.rawValue) {
                        guard let assets = previewPaths[day.rawValue] else { continue }
                        let dayDir = folder.appendingPathComponent(day.folderName)
                        for (_, srcPath) in assets where srcPath.hasSuffix(".png") {
                            guard FileManager.default.fileExists(atPath: srcPath) else { continue }
                            let src = URL(fileURLWithPath: srcPath)
                            let dest = dayDir.appendingPathComponent(src.lastPathComponent)
                            try? FileManager.default.removeItem(at: dest)
                            _ = try? FileManager.default.copyItem(at: src, to: dest)
                        }
                    }
                } catch {
                    mediaError = error.localizedDescription
                }
            }

            finishSuccess(eventID: eventID, folder: folder, onlyDay: onlyDay,
                          daysNeedingPython: daysNeedingPython, mediaError: mediaError, appState: appState)
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
                               daysNeedingPython: [String], mediaError: String?, appState: AppState) {
        // Only learn from full copy-only runs so the mean stays a clean signal
        // for the common fast path.
        if onlyDay == nil && daysNeedingPython.isEmpty {
            TimingStore.shared.recordMediaExport(seconds: Double(tracker.job(for: eventID)?.elapsedSeconds ?? 0))
        }

        tracker.update(eventID) {
            $0.task = nil
            $0.phase = .done(folder, mediaError: mediaError)
        }
        tracker.deactivate(eventID)

        // A full export is the real "Exported" milestone: stamp the live event
        // so the sidebar pill stops reading "Ready to Export" and the archive
        // clock starts from actual completion. Single-day re-exports don't.
        if onlyDay == nil, var ev = appState.events.first(where: { $0.id == eventID }) {
            ev.exportPath = folder
            ev.archivedAt = Date()
            appState.updateEvent(ev)
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
        let cells: [CollageCell]? = {
            if let override = pd?.collageCellOverride, !override.isEmpty { return override }
            let layoutURL = baseURL.deletingLastPathComponent()
                .appendingPathComponent(baseURL.deletingPathExtension().lastPathComponent + "_layout.json")
            guard let data = try? Data(contentsOf: layoutURL),
                  let decoded = try? JSONDecoder().decode([CollageCell].self, from: data),
                  !decoded.isEmpty
            else { return nil }
            return decoded
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
