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

    /// The keys of a per-day report, in week order, with any non-day key last.
    ///
    /// A dictionary has no order, so without this the same trouble reads
    /// differently on each run and looks like a different problem. A key that
    /// is not a day name (Python can report a run-level failure) still has to
    /// appear, or the message claims fewer problems than there are.
    private static func orderedKeys(_ report: [String: String]) -> [String] {
        let days = report.keys
            .compactMap { DayName(rawValue: $0) }
            .sorted { DayName.allCases.firstIndex(of: $0)! < DayName.allCases.firstIndex(of: $1)! }
            .map(\.rawValue)
        return days + report.keys.filter { DayName(rawValue: $0) == nil }.sorted()
    }

    private static func displayName(_ key: String) -> String {
        DayName(rawValue: key)?.displayName ?? key
    }

    /// One sentence naming which days failed, or nil when none did.
    ///
    /// Every entry counts. Before #265 this was not true: Python filed a note
    /// here for a day that rendered perfectly well with an OPTIONAL input
    /// missing, so the caller had to guess which entries were real failures by
    /// checking whether the day had produced any files. Warnings now have their
    /// own field, so `errors` means failed and nothing else.
    ///
    /// Nil rather than an empty string, so a caller cannot put an empty banner
    /// on every successful export, which is how a real warning stops being read.
    static func sentence(_ errors: [String: String]) -> String? {
        let named = orderedKeys(errors).map(displayName)
        guard !named.isEmpty else { return nil }

        let list = named.count == 1
            ? named[0]
            : named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
        let subject = named.count == 1 ? "day's graphics" : "days' graphics"
        return "\(list): the \(subject) could not be generated, so the export "
             + "folder is missing them. Check the log for why, then regenerate."
    }

    /// What a day was missing when it rendered anyway, or nil when nothing was.
    ///
    /// Unlike a failure's reason (ffmpeg stderr, which tells Dan nothing he can
    /// act on) a warning's reason is written by our own code and names the file
    /// that has moved, which is the actionable part. So it is quoted, and it
    /// says plainly that the folder is complete: a warning that reads like a
    /// loss is the defect this split exists to fix.
    static func warningSentence(_ warnings: [String: String]) -> String? {
        let keys = orderedKeys(warnings)
        guard !keys.isEmpty else { return nil }

        let lines = keys.map { "\(displayName($0)): \(warnings[$0] ?? "")" }
        let subject = keys.count == 1 ? "That day was" : "Those days were"
        return lines.joined(separator: "\n")
             + "\n\n\(subject) exported without the missing input, so nothing is "
             + "missing from the folder."
    }
}
