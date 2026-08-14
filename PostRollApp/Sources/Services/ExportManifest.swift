import Foundation

/// A record written into a finished export folder saying what it contains
/// (#184).
///
/// The folder is the handoff to actually posting, and it carried no sign of
/// whether the export finished. A run interrupted partway (a crash, a quit, a
/// cancelled media step) left a folder that differed from a complete one only
/// by having fewer files in it, and the app may have been restarted since, so
/// the folder is the only place left to catch it. Verifying one by hand meant
/// listing 33 files across seven day folders.
///
/// Its PRESENCE is the completion signal, which is why it is written last and
/// only on a run that finished everything. A partial run has no manifest, which
/// is the honest state: an empty or half-written manifest would be worse than
/// none, because it would look like an answer.
enum ExportManifest {

    static let filename = "export_manifest.json"

    /// What was in the folder when the export finished.
    struct Contents: Codable, Equatable {
        var exportedAt: Date
        var preset: String
        var event: String
        /// Day folder name to the files inside it, sorted, so two manifests of
        /// the same folder compare equal.
        var filesByDay: [String: [String]]
        var totalFiles: Int
        /// Folders that could not be listed while this was built, and why
        /// (#451). A day whose listing failed used to be recorded as holding
        /// zero files, which is a certificate of the folder's contents saying
        /// something it never read.
        var unreadableFolders: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case exportedAt, preset, event, filesByDay, totalFiles, unreadableFolders
        }

        init(exportedAt: Date, preset: String, event: String,
             filesByDay: [String: [String]], totalFiles: Int,
             unreadableFolders: [String: String] = [:]) {
            self.exportedAt = exportedAt
            self.preset = preset
            self.event = event
            self.filesByDay = filesByDay
            self.totalFiles = totalFiles
            self.unreadableFolders = unreadableFolders
        }

        // Manifests written before this field existed decode without it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exportedAt = try c.decode(Date.self, forKey: .exportedAt)
            preset     = try c.decode(String.self, forKey: .preset)
            event      = try c.decode(String.self, forKey: .event)
            filesByDay = try c.decode([String: [String]].self, forKey: .filesByDay)
            totalFiles = try c.decode(Int.self, forKey: .totalFiles)
            unreadableFolders =
                try c.decodeIfPresent([String: String].self, forKey: .unreadableFolders) ?? [:]
        }
    }

    /// Read what is actually on disk rather than what the export meant to
    /// write. A manifest built from intentions would list a file the copy step
    /// dropped, which is the exact failure it exists to catch (#79).
    static func build(folder: URL, preset: PostingPreset, event: String,
                      now: Date = Date()) -> Contents {
        let fm = FileManager.default
        var byDay: [String: [String]] = [:]
        var unreadable: [String: String] = [:]
        var total = 0

        let listing = DirectoryListing.of(folder, keys: [.isDirectoryKey], fileManager: fm)
        if let reason = listing.failureReason { unreadable[""] = reason }
        for entry in listing.entriesIgnoringFailure {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                // A day folder that could not be listed is recorded as such
                // rather than as a day holding nothing, because this file is a
                // certificate of what the folder contains (#451).
                let inside = DirectoryListing.of(entry, fileManager: fm)
                if let reason = inside.failureReason {
                    unreadable[entry.lastPathComponent] = reason
                    continue
                }
                let files = inside.entriesIgnoringFailure.map(\.lastPathComponent).sorted()
                byDay[entry.lastPathComponent] = files
                total += files.count
            } else if entry.lastPathComponent != filename {
                // Root-level files (CAPTIONS.txt) counted under a fixed key so
                // the total is the whole folder, not just the day folders.
                byDay["", default: []].append(entry.lastPathComponent)
                total += 1
            }
        }
        byDay[""]?.sort()

        return Contents(exportedAt: now, preset: preset.rawValue, event: event,
                        filesByDay: byDay, totalFiles: total,
                        unreadableFolders: unreadable)
    }

    /// Write the manifest, reporting whether it landed.
    ///
    /// A manifest that failed to write must not be treated as written: its
    /// absence is what a later reader uses to conclude the export is
    /// incomplete, so a silent failure here would mark a good export as bad.
    /// That is the safe direction of the two, but the caller should still know.
    @discardableResult
    static func write(_ contents: Contents, to folder: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(contents) else { return false }
        do {
            try data.write(to: folder.appendingPathComponent(filename), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// What the export screen says when the manifest could not be written
    /// (#452).
    ///
    /// The files ARE there, which is the part to say first, and the consequence
    /// is specific rather than vague: this folder will read as unfinished every
    /// time Dan comes back to it, because the record is what says otherwise.
    static let writeFailureNotice =
        "The export finished and the files are in the folder, but the small record that "
        + "says so could not be written into it. Nothing is missing; the folder will just "
        + "read as unfinished when you come back to it. Exporting again will write it."

    /// What the export screen says when the manifest was written but part of
    /// the folder could not be read while building it (#451).
    ///
    /// Returns nil when everything was readable, so nothing is shown on the
    /// ordinary run.
    static func unreadableNotice(_ contents: Contents) -> String? {
        guard !contents.unreadableFolders.isEmpty else { return nil }
        let named = contents.unreadableFolders.keys.sorted()
            .map { $0.isEmpty ? "the export folder itself" : $0 }
            .joined(separator: ", ")
        return "The export finished, but the record of what is in the folder is incomplete: "
             + "\(named) could not be read while it was written, so the file count leaves "
             + "\(contents.unreadableFolders.count == 1 ? "it" : "them") out. Check the "
             + "folder before posting."
    }

    /// Whether this folder holds a finished export.
    static func isComplete(folder: URL) -> Bool {
        read(folder: folder) != nil
    }

    static func read(folder: URL) -> Contents? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(filename))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Contents.self, from: data)
    }
}
