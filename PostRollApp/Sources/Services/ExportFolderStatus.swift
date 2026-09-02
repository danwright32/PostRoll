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

    /// The recorded export folder is not at the recorded path, so the app no
    /// longer knows where that export is (#1110).
    ///
    /// Deliberately NOT called `folderGone`, and deliberately not a warning.
    /// An absent path is evidence the APP has lost the thread, never evidence
    /// the export was lost (L11), and here the two are almost never the same
    /// thing: measured against the live store on 2026-09-02, 9 of 21 events
    /// record an export path and 0 of those 9 folders are at it, because Dan
    /// files every finished export into one of his own Finder buckets when he
    /// is done with it. The warning this used to raise was therefore wrong on
    /// 9 of 9, and the step it named (export again) would have had him redo
    /// work already sitting finished in one of those buckets (L36, L111).
    ///
    /// Automatically re-finding the folder was measured and rejected (L248):
    /// searching down from the nearest ancestor that still exists found 0 of
    /// the 9, because the buckets are siblings and the surviving ancestor is
    /// always the wrong one. Widening the search to the bucket root found 5 of
    /// 9, which is a guess about where a finished export lives that is wrong 4
    /// times in 9, so the app says what it knows and asks instead.
    case lostTrack(URL)

    /// The folder holds a finished export.
    ///
    /// `unreadableDayFolders` are the days the export run itself could not list,
    /// carried from the manifest's own record of them (#451). Empty is the
    /// ordinary case. When it is not empty the run finished, but `fileCount` is
    /// a count of what it could see rather than of what is there, and it says
    /// so: a certificate that cannot mention its own gap is a certificate
    /// claiming something it never read, which is what recording the field was
    /// for. It was written and shown at write time and ignored on the way back
    /// in until #540.
    case finished(exportedAt: Date, fileCount: Int, unreadableDayFolders: [String] = [])

    /// The folder exists and has no manifest, so the run that made it did not
    /// finish. `emptyDayFolders` and `hasCaptions` are read off the folder
    /// itself, because with no manifest there is no record of what was meant to
    /// be there and guessing would be worse than saying what is missing now.
    case unfinished(fileCount: Int, emptyDayFolders: [String], hasCaptions: Bool,
                    unreadableDayFolders: [String] = [])

    /// The folder is there and could not be listed, so nothing can be said
    /// about what is in it (#451). Its own case rather than folding into
    /// `unfinished`, because the two need opposite responses: exporting again
    /// into a folder the app is not allowed to read fixes nothing.
    case unreadable(String)

    /// Read the folder recorded on `event`.
    static func of(_ event: Event, fileManager: FileManager = .default) -> ExportFolderStatus {
        guard let folder = event.exportPath else { return .neverExported }
        return of(folder: folder, fileManager: fileManager)
    }

    static func of(folder: URL, fileManager: FileManager = .default) -> ExportFolderStatus {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue
        else { return .lostTrack(folder) }

        if let contents = ExportManifest.read(folder: folder) {
            return .finished(exportedAt: contents.exportedAt,
                             fileCount: contents.totalFiles,
                             unreadableDayFolders: contents.unreadableFolders.keys.sorted())
        }

        // No manifest, so what follows is read off the folder. A folder that
        // cannot be listed says so: reporting it as an export that never
        // finished, with advice to run it again, sends Dan at the one fix that
        // cannot work (#451).
        let listing = DirectoryListing.of(folder, keys: [.isDirectoryKey],
                                          fileManager: fileManager)
        if let reason = listing.failureReason { return .unreadable(reason) }

        var fileCount = 0
        var empties: [String] = []
        var unreadableDays: [String] = []
        var hasCaptions = false
        for entry in listing.entriesIgnoringFailure {
            let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isFolder {
                // A day folder that cannot be listed is its own answer too. It
                // is the same defect one level down: counted as zero files, it
                // would be reported as an empty day and read as an export that
                // lost that day's files.
                let inside = DirectoryListing.of(entry, fileManager: fileManager)
                guard case .entries(let files) = inside else {
                    unreadableDays.append(entry.lastPathComponent)
                    continue
                }
                fileCount += files.count
                if files.isEmpty { empties.append(entry.lastPathComponent) }
            } else {
                fileCount += 1
                if entry.lastPathComponent == "CAPTIONS.txt" { hasCaptions = true }
            }
        }
        return .unfinished(fileCount: fileCount,
                           emptyDayFolders: empties.sorted(),
                           hasCaptions: hasCaptions,
                           unreadableDayFolders: unreadableDays.sorted())
    }

    /// How loudly this wants to be said, if at all.
    enum Attention { case none, informational, warning }

    /// The screen takes both the banner style and whether to draw one from
    /// here, so "is this worth saying" and "is this a fault" cannot drift into
    /// two answers (L53).
    var attention: Attention {
        switch self {
        case .neverExported:
            return .none
        // A finished export is the expected state and does not need a banner on
        // every visit. One whose own record admits it could not read a day is a
        // different thing: the count Dan would otherwise trust is missing that
        // day, and nothing else on the screen would ever say so.
        case .finished(_, _, let unreadable):
            return unreadable.isEmpty ? .none : .warning
        // Said, because the app knowing where an export went is worth being
        // able to restore, but not as a fault: see `lostTrack`.
        case .lostTrack:
            return .informational
        case .unfinished, .unreadable:
            return .warning
        }
    }

    /// Whether this is worth showing at all.
    var needsAttention: Bool { attention != .none }

    /// One sentence for the screen, or nil when there is nothing to say.
    ///
    /// Says what is wrong AND where to go, because a message that names a
    /// problem and offers nowhere to act leaves the person stuck (L80). For
    /// most of these the route out is to export again; for a folder the app
    /// cannot read it is not, and saying so is the point of that case.
    var message: String? {
        switch self {
        case .neverExported:
            return nil

        case .lostTrack(let folder):
            // Names the folder, because a message about something Dan has to go
            // and find is worth nothing without the thing to search for (L80).
            // Claims only what was measured: that it is not at the recorded
            // path. Whether it was filed away, renamed or deleted is not
            // something a failed `fileExists` can tell apart, so it is offered
            // as the likely reason rather than asserted.
            return "PostRoll has lost track of the export folder "
                 + "\(folder.lastPathComponent). It is not where it was written any "
                 + "more, which is what happens when a finished export is moved, "
                 + "renamed or filed away. Point PostRoll at it again to say where "
                 + "it went."

        case .finished(let at, let count, let unreadable):
            let when = DateFormatter.exportStamp.string(from: at)
            let noun = count == 1 ? "file" : "files"
            guard !unreadable.isEmpty else {
                return "Exported \(when): \(count) \(noun) in the folder."
            }
            // The count stops presenting as the whole export, because the day it
            // could not read is exactly the part it did not count. Same wording
            // as the unfinished case uses for the same fact, and the same route
            // out, since exporting again lands in the same unreadable folder.
            return "Exported \(when): \(count) \(noun) counted. "
                 + "\(unreadable.joined(separator: ", ")) could not be read during the "
                 + "export, so \(unreadable.count == 1 ? "that day is" : "those days are") "
                 + "not in that count and there is no telling what is in "
                 + "\(unreadable.count == 1 ? "it" : "them"). Grant access under System "
                 + "Settings > Privacy & Security > Files and Folders, then export again."

        case .unreadable(let reason):
            return "That export folder is there but PostRoll cannot read it, so there is "
                 + "no telling what is in it. " + Sentence.closed(reason)
                 + " Grant access under System Settings > Privacy & Security > Files and "
                 + "Folders, or move the folder somewhere PostRoll can read. Exporting "
                 + "again would land in the same place."

        case .unfinished(let count, let empties, let hasCaptions, let unreadableDays):
            var parts = ["That export folder was never finished, so it is missing files."]
            if !hasCaptions { parts.append("CAPTIONS.txt is not in it.") }
            if !empties.isEmpty {
                parts.append("\(empties.joined(separator: ", ")) "
                             + (empties.count == 1 ? "is empty." : "are empty."))
            }
            // Named apart from the empty ones: those are days that lost their
            // files, these are days nothing could look inside, and only one of
            // the two is fixed by exporting again.
            if !unreadableDays.isEmpty {
                parts.append("\(unreadableDays.joined(separator: ", ")) could not be read, "
                             + "so what is in \(unreadableDays.count == 1 ? "it" : "them") "
                             + "is unknown.")
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

    /// The same date without the time, for a list row where the hour is noise
    /// (#925). Declared beside `exportStamp` rather than near its own call
    /// site, so the two renderings of an export date are decided in one place
    /// and cannot drift into two house styles (L39).
    static let exportDay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
