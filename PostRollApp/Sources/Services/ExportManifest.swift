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
    }

    /// Read what is actually on disk rather than what the export meant to
    /// write. A manifest built from intentions would list a file the copy step
    /// dropped, which is the exact failure it exists to catch (#79).
    static func build(folder: URL, preset: PostingPreset, event: String,
                      now: Date = Date()) -> Contents {
        let fm = FileManager.default
        var byDay: [String: [String]] = [:]
        var total = 0

        let entries = (try? fm.contentsOfDirectory(at: folder,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let files = ((try? fm.contentsOfDirectory(at: entry,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? [])
                    .map(\.lastPathComponent)
                    .sorted()
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
                        filesByDay: byDay, totalFiles: total)
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
