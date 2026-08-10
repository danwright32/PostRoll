import Foundation

/// Whether the folder an event was exported to actually holds a finished
/// export, read from the manifest (#247).
///
/// `ExportManifest` is written last and only by a run that lost nothing, so its
/// presence is the completion signal and an interrupted run leaves none (#184).
/// `isComplete` and `read` existed and nothing called them, which meant only a
/// person opening the folder in Finder could use the record, and a field that
/// is only ever written looks alive to any is-this-used check while its purpose
/// silently never happens (L46).
///
/// The moment the incompleteness is worth knowing is when Dan comes back to an
/// exported event, not when he is already standing in Finder.
enum ExportFolderStatus: Equatable {

    /// The event has never been exported. Not a problem, just nothing to say.
    case neverExported

    /// The event records an export folder that is no longer on disk (moved,
    /// renamed, or on a drive that is not attached).
    case folderGone(URL)

    /// The folder holds a finished export.
    case finished(exportedAt: Date, fileCount: Int)

    /// The folder exists and has no manifest, so the run that made it did not
    /// finish. `emptyDayFolders` and `hasCaptions` are read off the folder
    /// itself, because with no manifest there is no record of what was meant to
    /// be there and guessing would be worse than saying what is missing now.
    case unfinished(fileCount: Int, emptyDayFolders: [String], hasCaptions: Bool)

    /// Read the folder recorded on `event`.
    static func of(_ event: Event, fileManager: FileManager = .default) -> ExportFolderStatus {
        guard let folder = event.exportPath else { return .neverExported }
        return of(folder: folder, fileManager: fileManager)
    }

    static func of(folder: URL, fileManager: FileManager = .default) -> ExportFolderStatus {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue
        else { return .folderGone(folder) }

        if let contents = ExportManifest.read(folder: folder) {
            return .finished(exportedAt: contents.exportedAt, fileCount: contents.totalFiles)
        }

        var fileCount = 0
        var empties: [String] = []
        var hasCaptions = false
        let entries = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isFolder {
                let inside = ((try? fileManager.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? [])
                fileCount += inside.count
                if inside.isEmpty { empties.append(entry.lastPathComponent) }
            } else {
                fileCount += 1
                if entry.lastPathComponent == "CAPTIONS.txt" { hasCaptions = true }
            }
        }
        return .unfinished(fileCount: fileCount,
                           emptyDayFolders: empties.sorted(),
                           hasCaptions: hasCaptions)
    }

    /// Whether this is worth showing at all. A finished export is the expected
    /// state and does not need a banner on every visit.
    var needsAttention: Bool {
        switch self {
        case .neverExported, .finished: return false
        case .folderGone, .unfinished:  return true
        }
    }

    /// One sentence for the screen, or nil when there is nothing to say.
    ///
    /// Says what is wrong AND where to go, because a message that names a
    /// problem and offers nowhere to act leaves the person stuck (L80). The
    /// route out of every bad case here is the same: export again.
    var message: String? {
        switch self {
        case .neverExported:
            return nil

        case .folderGone(let folder):
            return "The export folder \(folder.lastPathComponent) is no longer where it was. "
                 + "It may have been moved or renamed, or be on a drive that is not connected. "
                 + "Export again to make a fresh one."

        case .finished(let at, let count):
            let when = DateFormatter.exportStamp.string(from: at)
            return "Exported \(when): \(count) \(count == 1 ? "file" : "files") in the folder."

        case .unfinished(let count, let empties, let hasCaptions):
            var parts = ["That export folder was never finished, so it is missing files."]
            if !hasCaptions { parts.append("CAPTIONS.txt is not in it.") }
            if !empties.isEmpty {
                parts.append("\(empties.joined(separator: ", ")) "
                             + (empties.count == 1 ? "is empty." : "are empty."))
            }
            parts.append("\(count) \(count == 1 ? "file is" : "files are") there now. Export again.")
            return parts.joined(separator: " ")
        }
    }
}

extension DateFormatter {
    /// Dates on the export screen. Its own formatter so the wording is decided
    /// once rather than per call site.
    static let exportStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
