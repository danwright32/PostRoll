import Foundation

/// Where a day's cached assets live, taken from a path the run that made them
/// produced (#925).
///
/// The folder name is Python's to choose, so it is never rebuilt from the event
/// and the day: a second derivation would break silently the first time that
/// naming changed. One implementation, shared by the review strip that badges a
/// day and the export that records one, so the two cannot come to name
/// different folders for the same day (L263).
enum PreviewDayFolder {

    /// The folder holding a day's assets, or nil when nothing recorded for that
    /// day is still on disk.
    ///
    /// Sorted before the search so two calls over the same day answer the same
    /// way. Every asset of one day sits in one folder, so the order cannot
    /// change WHICH folder is named, but an unordered dictionary walk makes the
    /// path a run reports depend on nothing anybody chose (L343).
    static func url(paths: [String: String]?,
                    fileManager: FileManager = .default) -> URL? {
        guard let path = paths?.values.sorted()
            .first(where: { fileManager.fileExists(atPath: $0) })
        else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }
}

/// A record written into a PREVIEW day folder saying that day's assets have
/// been exported (#925).
enum DayExportRecord {

    /// The record's name inside a preview day folder, beside `design.json`.
    /// The two answer neighbouring questions about the same day: what made
    /// these assets, and whether they have gone anywhere.
    static let filename = "exported.json"

    /// What the file holds. A struct rather than a bare date so a later field
    /// can be added without every existing record becoming unreadable, which is
    /// the shape `ExportManifest.Contents` already takes.
    struct Contents: Codable, Equatable {
        var exportedAt: Date
    }

    // MARK: - Reading

    /// When this day was last exported, or nil when nothing says it ever was.
    ///
    /// Nil is "nothing here says so", NOT "this day was never exported". Every
    /// day folder rendered before this record existed is in that state, and the
    /// surface that reads this has to keep the two apart: a day nobody can
    /// speak for must not be reported as one that never shipped (L98, L214).
    ///
    /// Never throws. A file that is not a record reads as no record rather than
    /// as a date, because a value that cannot be parsed must not become one
    /// that marks a day finished on evidence nobody wrote (L50).
    static func read(in dayDir: URL) -> Date? {
        guard let data = try? Data(contentsOf: dayDir.appendingPathComponent(filename))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Contents.self, from: data))?.exportedAt
    }

    // MARK: - Writing

    /// Record that this day's assets went out, reporting whether it landed.
    ///
    /// The answer is not discarded. The ABSENCE of this record is what makes a
    /// stale day read as work still worth doing, so a write that failed leaves
    /// a finished day padding that list with nothing anywhere saying why
    /// (#452 made the same argument about the export manifest's own write).
    ///
    /// The latest export wins. A day exported twice went out most recently on
    /// the second run, and that is the date worth holding.
    @discardableResult
    static func write(exportedAt: Date, in dayDir: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Contents(exportedAt: exportedAt))
        else { return false }
        do {
            try data.write(to: dayDir.appendingPathComponent(filename), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Stamp every day an export actually wrote, returning the days it could
    /// not record.
    ///
    /// Named rather than swallowed, for the reason above: a day the export
    /// wrote but PostRoll could not record goes on reading as one that never
    /// went out, and the caller is the only thing in a position to say so.
    ///
    /// Days are named by the caller rather than derived here from the event,
    /// because the export is what knows which days it wrote: a single day
    /// re-export must not leave a claim about the rest of the week (L166).
    @discardableResult
    static func stamp(days: [DayName], in event: Event, at now: Date) -> [DayName] {
        days.filter { day in
            guard let folder = PreviewDayFolder.url(paths: event.previewMediaPaths[day.rawValue])
            else { return true }
            return !write(exportedAt: now, in: folder)
        }
    }

    /// What the export screen says about days it exported and could not record.
    ///
    /// Nil when everything landed, so nothing is shown on the ordinary run.
    ///
    /// Says what is TRUE first: the export finished and the files are there.
    /// Then the consequence, which is specific rather than vague, because the
    /// absence of this record is exactly what keeps a day in the outdated
    /// designs list as work still worth doing. Then the way out, which is a
    /// step that genuinely changes the state Dan is in (L111): exporting the
    /// day again writes the record.
    static func recordFailureNotice(_ days: [DayName]) -> String? {
        guard !days.isEmpty else { return nil }
        let named = days.map(\.displayName).joined(separator: ", ")
        let one = days.count == 1
        return "The export finished and the files are in the folder, but the note "
             + "saying \(one ? "this day" : "these days") went out could not be written: "
             + "\(named). Nothing is missing from the export. "
             + "\(one ? "That day" : "Those days") will keep appearing in Outdated "
             + "Designs as work worth doing, because that note is what sets an "
             + "already exported day aside. Exporting "
             + "\(one ? "it" : "them") again will write it."
    }
}
