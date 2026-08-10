import Foundation

/// Turning per-day media failures into one sentence for the export screen (#262).
///
/// `generate_media.py` reports a failure per day and exits zero, so a run that
/// lost a day looks identical to a clean one from the process's point of view.
/// The export path read none of it, which meant an export could report success
/// over a folder that was quietly missing an asset.
///
/// Naming the days matters more than the reasons: Dan's next move is to look in
/// that day's folder, and a wall of ffmpeg output tells him nothing he can act
/// on. The reasons stay available in the log.
enum MediaErrorSummary {

    /// The days whose graphics genuinely did not render.
    ///
    /// `errors` is not a list of failures. `generate_media` records a note there
    /// for a day that rendered perfectly well with an OPTIONAL input missing (a
    /// removed B&W photo), so treating every entry as a failure claims files are
    /// missing that are sitting in the folder, and blocks the export from ever
    /// being marked done. A day is only failed here if it produced nothing.
    ///
    /// Two different facts sharing one field is the underlying problem and it
    /// lives on the Python side; this is the honest reading of it until then.
    static func failures(errors: [String: String],
                         paths: [String: [String: String]]) -> [String: String] {
        errors.filter { key, _ in (paths[key]?.isEmpty ?? true) }
    }

    /// One sentence naming which days failed, or nil when none did.
    ///
    /// Nil rather than an empty string, so a caller cannot put an empty banner
    /// on every successful export, which is how a real warning stops being read.
    static func sentence(_ errors: [String: String]) -> String? {
        let days = errors.keys
            .compactMap { DayName(rawValue: $0) }
            .sorted { DayName.allCases.firstIndex(of: $0)! < DayName.allCases.firstIndex(of: $1)! }
            .map(\.displayName)

        // A key that is not a day name (Python can report a run-level failure)
        // still has to be counted, or the sentence claims fewer problems than
        // there are.
        let other = errors.keys.filter { DayName(rawValue: $0) == nil }.sorted()
        let named = days + other
        guard !named.isEmpty else { return nil }

        let list = named.count == 1
            ? named[0]
            : named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
        let subject = named.count == 1 ? "day's graphics" : "days' graphics"
        return "\(list): the \(subject) could not be generated, so the export "
             + "folder is missing them. Check the log for why, then regenerate."
    }
}
