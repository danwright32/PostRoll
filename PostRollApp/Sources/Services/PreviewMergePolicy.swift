import Foundation

/// Pure decisions for how a generation run handles preview graphics, extracted
/// from GenerationManager so they can be unit-tested without the async task,
/// PythonBridge, or AppState.
enum PreviewMergePolicy {

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
    @discardableResult
    static func copyPreviewAssetsIfComplete(
        assets: [String: String]?,
        to dayDir: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let assets, !assets.isEmpty,
              assets.values.allSatisfy({ fileManager.fileExists(atPath: $0) })
        else { return false }

        try? fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        for (_, srcPath) in assets {
            let src = URL(fileURLWithPath: srcPath)
            let dest = dayDir.appendingPathComponent(src.lastPathComponent)
            try? fileManager.removeItem(at: dest)
            _ = try? fileManager.copyItem(at: src, to: dest)
        }
        return true
    }
}
