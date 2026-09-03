import Foundation

/// Pure decisions for how a generation run handles preview graphics, extracted
/// from GenerationManager so they can be unit-tested without the async task,
/// PythonBridge, or AppState.
/// What a finished day redraw actually produced, for one named day (#1009).
///
/// Lifted out of `CaptionReviewView.applyRegenResult`, where it was three
/// branches inside a private method on a SwiftUI view. That is what made a day
/// scoped redraw unusable from any other screen, and it also meant the branch
/// itself could not be tested.
///
/// Two of the three outcomes are failures a run exiting ZERO still produces:
/// Python reporting a per day error, and Python reporting nothing at all for
/// the day it was asked about. Both were once swallowed by a `try?`, which
/// fired the completion notification while the old graphic stayed on screen.
enum DayRedrawOutcome: Equatable {
    case succeeded([String: String])
    case failed(String)

    /// Judges `day` alone.
    ///
    /// Another day's error is not this day's problem: a redraw claims named
    /// days, and folding the whole result's errors into one verdict fails a day
    /// that rendered perfectly because a different one did not (L53).
    static func of(_ result: PythonBridge.PreviewGenerationResult,
                   day: DayName) -> DayRedrawOutcome {
        // The pipeline's own text, unwrapped: the marker it uses for the cases
        // that have a remedy has to survive to the card that offers one (#730,
        // L199). Checked BEFORE the paths, because a run can write a file and
        // still report the day as failed, and the error is the truer answer.
        if let pipelineError = result.errors[day.rawValue] {
            return .failed(pipelineError)
        }
        guard let paths = result.paths[day.rawValue], !paths.isEmpty else {
            // An empty set of paths is nothing rendered, which is a different
            // sentence from a pipeline error and needs its own (L11). Reported
            // as a failure rather than a quiet success, because the screen
            // otherwise goes on showing the graphic this run was meant to
            // replace.
            return .failed("\(day.displayName) regeneration produced no output")
        }
        return .succeeded(paths)
    }
}

enum PreviewMergePolicy {

    /// The days a run actually produced images for.
    ///
    /// Keys alone are not the answer: a day can appear carrying an empty set of
    /// paths, which is a day that rendered NOTHING, and recording that as a
    /// finished render would mark the failure as up to date (L67). One spelling
    /// of the question, because its three callers each write it once and the
    /// one that gets it wrong is invisible.
    static func renderedDays(in paths: [String: [String: String]]?) -> [String] {
        (paths ?? [:]).filter { !$0.value.isEmpty }.map(\.key)
    }

    /// Whether a run should (re)render preview graphics.
    ///
    /// By default graphics render only on a full run (captions and graphics in
    /// parallel); partial retries skip them to keep a single caption re-edit
    /// fast. `regenerateGraphics` overrides that — the preset switch passes
    /// `true` so a partial retry of the affected days also rebuilds their media.
    static func shouldRenderGraphics(regenerateGraphics: Bool?, isFullRun: Bool) -> Bool {
        regenerateGraphics ?? isFullRun
    }

    /// Fold freshly rendered preview paths into the existing map. A full run
    /// replaces the whole map; a partial retry merges only the regenerated days
    /// so other days' approved previews survive. Empty `fresh` leaves the
    /// existing map untouched.
    static func merge(existing: [String: [String: String]],
                      fresh: [String: [String: String]]?,
                      isFullRun: Bool) -> [String: [String: String]] {
        guard let fresh, !fresh.isEmpty else { return existing }
        if isFullRun { return fresh }
        var merged = existing
        for (day, paths) in fresh { merged[day] = paths }
        return merged
    }

    /// Assets a day no longer has, and must not carry from before it lost them.
    ///
    /// Thursday's cover went in #961: it was a full story composite on a day
    /// Dan posts no story, and Instagram picks its own grid thumbnail from a
    /// frame of the reel. Removing it stopped the cover being RENDERED, and
    /// stopped the panel drawing one, but every Thursday generated before that
    /// still names a `cover` in events.json.
    ///
    /// That is not inert. The export copies already approved previews where it
    /// can rather than always re-rendering, and it copies whatever keys a day
    /// has, generically. So the stale path would put a story into the folder
    /// Dan uploads from, which is the one thing #961 said must not happen.
    static let retiredAssets: [String: Set<String>] = ["thursday": ["cover"]]

    /// The stored paths with anything retired dropped.
    ///
    /// Applied when an event is DECODED, so every reader sees the same thing
    /// and the file is cleaned the next time it is saved. Doing it at the
    /// export instead would leave the path in the event for the next surface
    /// that reads one.
    static func withoutRetiredAssets(
        _ paths: [String: [String: String]]
    ) -> [String: [String: String]] {
        var cleaned = paths
        for (day, retired) in retiredAssets {
            guard var dayPaths = cleaned[day] else { continue }
            for asset in retired { dayPaths.removeValue(forKey: asset) }
            cleaned[day] = dayPaths
        }
        return cleaned
    }

    /// Key used for a graphics run that died outright rather than reporting a
    /// per-day failure. Names no day, so it can never be passed to --only-days.
    static let graphicsRunKey = "graphics"

    /// Fold a graphics run's per-day failures into the ones already recorded.
    ///
    /// `renderedDays` is the set of days this run actually re-rendered: nil for a
    /// full run (it owns every day, so `fresh` replaces the lot), and empty for a
    /// caption-only retry that skipped graphics entirely. Only rendered days are
    /// cleared, so a retry can never silently erase a failure it never re-attempted.
    static func mergeMediaErrors(existing: [String: String],
                                 fresh: [String: String],
                                 renderedDays: Set<String>?) -> [String: String] {
        guard let renderedDays else { return fresh }
        var merged = existing
        for day in renderedDays { merged.removeValue(forKey: day) }
        merged.merge(fresh) { _, new in new }
        return merged
    }

    /// Which days a graphics pass may speak for (#763).
    ///
    /// A pass that said NOTHING AT ALL owns no days, whatever it was asked to
    /// render. `runPreviewGeneration` answers with a wholly empty result when
    /// Python wrote no output file, or wrote something that would not parse,
    /// and on a full run `renderedDays` is nil, which means "this run owns
    /// every day". Folding that silence in as the run's answer erased every
    /// stored error and warning the event had: a read that comes back empty
    /// when it FAILS destroys the whole record, at the moment the record is
    /// worth having (L105).
    ///
    /// This is #740 one entry point over. That fixed the run started from the
    /// caption screen, through `PreviewGraphicsManager.applyFullRunResult`, and
    /// the generation run's own pass kept the hole.
    ///
    /// About SILENCE, not about having no errors. A run that rendered the week
    /// and found nothing wrong carries paths, so it still owns its days and
    /// still takes away the failures the run before recorded, or a day that has
    /// been fixed reports as broken forever (L14). A warning alone counts as
    /// having spoken for the same reason.
    ///
    /// One decision rather than a guard written separately at each of the four
    /// folds it has to cover: two `mergeMediaErrors` calls and a
    /// `recordDayOutcomes` call in each of the two completion paths.
    static func daysOwned(renderedDays: Set<String>?,
                          paths: [String: [String: String]]?,
                          errors: [String: String],
                          warnings: [String: String]) -> Set<String>? {
        let saidNothing = (paths?.isEmpty ?? true) && errors.isEmpty && warnings.isEmpty
        return saidNothing ? [] : renderedDays
    }

    /// How to retry a set of failed keys. A graphics failure needs its day's media
    /// re-rendered, which the default partial retry skips, so the retry button
    /// would otherwise appear to do nothing. `days` nil means run the whole thing:
    /// the only failure left is the non-day graphics crash key.
    static func retryPlan(failedKeys: Set<String>, mediaErrorKeys: Set<String>)
        -> (days: Set<String>?, regenerateGraphics: Bool?) {
        let dayKeys = failedKeys.filter { $0 != graphicsRunKey }
        guard !dayKeys.isEmpty else { return (nil, nil) }
        let needsGraphics = dayKeys.contains { mediaErrorKeys.contains($0) }
        return (dayKeys, needsGraphics ? true : nil)
    }

    /// Attempts to satisfy one day's exported assets purely from already-
    /// rendered previews (no Python regen): every listed asset file must
    /// still exist on disk. Generic over asset key by construction: a
    /// "cover" entry (#141's Instagram grid cover images) copies exactly
    /// like "reel", "story", or any other key, no exclusions needed.
    /// Extracted from ExportManager so it's testable with real files
    /// instead of Task/AppState/security-scoped URLs.
    /// What the fast copy path actually did.
    ///
    /// `satisfied` is the only thing a caller may read as "this day is done".
    /// The pre-check proves every SOURCE exists; it says nothing about whether
    /// the copies worked, and for a long time this returned a bare `true`
    /// regardless, so an export finished clean with the folder short a file
    /// (#357).
    struct PreviewCopyResult {
        /// Every source existed, so the fast path ran rather than declining.
        let attempted: Bool
        /// One entry per asset that could not be placed in the day folder.
        /// Same currency as every other copy in the export since #79, so these
        /// reach the user through the warning that already exists.
        let dropped: [EventExporter.DroppedAsset]

        /// Ran, and placed everything it promised.
        var satisfied: Bool { attempted && dropped.isEmpty }

        static let declined = PreviewCopyResult(attempted: false, dropped: [])
    }

    /// An approved preview that was not on disk when the export went to put it
    /// back over the freshly generated version.
    ///
    /// This is deliberately NOT a `DroppedAsset`: that says the folder is short
    /// a file, and here it is not. Python regenerated the day, so the folder
    /// holds a perfectly good image. What is missing is Dan's approval of it,
    /// and the two call for different words and different actions (#377).
    struct AbsentApproval: Equatable {
        /// How to name it to Dan, e.g. "Wednesday collage.png".
        let label: String
        let fileName: String
    }

    /// The approved previews for one day that are no longer on disk.
    ///
    /// Sorted by asset key so the same day reports the same way twice, rather
    /// than in whatever order the dictionary happened to hash.
    static func absentApprovals(
        assets: [String: String]?,
        label: String,
        fileManager: FileManager = .default
    ) -> [AbsentApproval] {
        guard let assets, !assets.isEmpty else { return [] }
        return assets.sorted { $0.key < $1.key }
            .filter { !fileManager.fileExists(atPath: $0.value) }
            .map { _, path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return AbsentApproval(label: "\(label) \(name)", fileName: name)
            }
    }

    /// What to tell Dan, or nil when every approval was used. Nil rather than
    /// an empty string so an ordinary export cannot render a blank notice,
    /// which is how a notice stops being read before the one time it matters.
    static func substitutionNotice(_ absent: [AbsentApproval]) -> String? {
        guard !absent.isEmpty else { return nil }
        let names = absent.map(\.label).joined(separator: ", ")
        let count = absent.count
        return "\(count) approved image\(count == 1 ? "" : "s") could not be found, so the "
            + "freshly generated version\(count == 1 ? " was" : "s were") exported instead "
            + "of the one\(count == 1 ? "" : "s") you approved: \(names)."
    }

    @discardableResult
    static func copyPreviewAssetsIfComplete(
        assets: [String: String]?,
        to dayDir: URL,
        label: String,
        fileManager: FileManager = .default
    ) -> PreviewCopyResult {
        guard let assets, !assets.isEmpty,
              assets.values.allSatisfy({ fileManager.fileExists(atPath: $0) })
        else { return .declined }

        try? fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)

        // Sorted so a failure reports the same way twice, rather than in
        // whatever order the dictionary happened to hash.
        let dropped = assets.sorted { $0.key < $1.key }.compactMap {
            place(URL(fileURLWithPath: $0.value), into: dayDir,
                  label: label, fileManager: fileManager)
        }
        return PreviewCopyResult(attempted: true, dropped: dropped)
    }

    /// Puts every approved asset that IS on disk back over a day the generator
    /// has just rebuilt, and returns whichever could not be placed.
    ///
    /// Unlike `copyPreviewAssetsIfComplete` this does not require all of them:
    /// this runs precisely because some are absent, and the absent ones are
    /// reported by `absentApprovals` rather than here.
    ///
    /// Every approved asset, not only the still images. The reel is an mp4 and
    /// is one of the things Dan approves, so restoring images alone shipped the
    /// machine's reel on any day that was regenerated (#383).
    static func restoreAvailableApprovals(
        assets: [String: String]?,
        to dayDir: URL,
        label: String,
        fileManager: FileManager = .default
    ) -> [EventExporter.DroppedAsset] {
        guard let assets, !assets.isEmpty else { return [] }
        try? fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        return assets.sorted { $0.key < $1.key }
            .filter { fileManager.fileExists(atPath: $0.value) }
            .compactMap {
                place(URL(fileURLWithPath: $0.value), into: dayDir,
                      label: label, fileManager: fileManager)
            }
    }

    /// Places one file in the day folder, returning a dropped asset when it
    /// could not be.
    ///
    /// Copies beside the destination first and only swaps once the whole file is
    /// there. Deleting first and copying second means a copy that fails has
    /// already taken the previous export's file with it, which is worse than not
    /// exporting at all (#357). One implementation, so the restore path cannot
    /// drift back to the unsafe order that the fast path already got right.
    private static func place(
        _ src: URL, into dayDir: URL, label: String, fileManager: FileManager
    ) -> EventExporter.DroppedAsset? {
        let dest = dayDir.appendingPathComponent(src.lastPathComponent)
        let staged = dayDir.appendingPathComponent(
            ".\(src.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: src, to: staged)
            if fileManager.fileExists(atPath: dest.path) {
                _ = try fileManager.replaceItemAt(dest, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: dest)
            }
            return nil
        } catch {
            try? fileManager.removeItem(at: staged)
            return EventExporter.DroppedAsset(
                label: "\(label) \(src.lastPathComponent)",
                source: src, reason: error.localizedDescription)
        }
    }
}
