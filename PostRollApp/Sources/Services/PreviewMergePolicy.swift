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
}
