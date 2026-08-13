import Foundation

/// Builds an export beside the one already on disk and swaps it in only once
/// the whole run has finished (#442).
///
/// What this replaces: the export deleted the previous folder before a single
/// replacement file existed, so any failure partway through (a text write that
/// throws, the Python media step dying, a full disk) had already destroyed the
/// last complete uploadable export. That is the order L5 exists to forbid, and
/// the codebase had already established the right one in
/// `PreviewMergePolicy.place` (#357): build somewhere else, swap at the end.
///
/// The staging folder is a real sibling directory holding a child with the
/// export's own name, because the Python media step derives the folder name
/// itself from the event and is handed only the parent. Staging the parent
/// therefore needs no change to that contract: Python writes into
/// `<staging>/<export name>` exactly as it would write into
/// `<destination>/<export name>`.
struct ExportStaging {

    /// Where the finished export belongs.
    let finalFolder: URL

    /// Where every step of this run actually writes. Becomes `finalFolder` on
    /// `commit`, and is deleted on `abandon`.
    let workingFolder: URL

    private let stagingRoot: URL

    /// The staging folders this process is currently using.
    ///
    /// Two events can export into one destination at the same time, so the
    /// sweep below has to leave a run that is still going. In-memory on
    /// purpose: after a crash it is empty, which is exactly right, because
    /// nothing left on disk then belongs to a live run.
    private static let live = LiveStagingFolders()

    /// Folders left by a run that never ended.
    ///
    /// A run that fails or is cancelled cleans up after itself, but a crash or
    /// a force quit ends nothing, so the folder stays in the person's own
    /// export destination holding a full part-built copy and nothing removes
    /// it. Swept at the start of the next export, which is the first moment the
    /// app has access to that folder again: it is one the person picked, and
    /// the security scope for it only exists while an export is running.
    private static func sweepAbandoned(in parent: URL) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) {
            let folder = parent.appendingPathComponent(name)
            guard !live.contains(folder) else { continue }
            do {
                try fm.removeItem(at: folder)
            } catch {
                // Named rather than swallowed: this is disk in a folder the
                // person opens, and a sweep that quietly fails leaves it there.
                NSLog("ExportStaging: could not remove abandoned \(name): \(error)")
            }
        }
    }

    private static let stagingPrefix = ".postroll-export-"

    /// Prepare a staging folder for an export of `finalFolder`.
    ///
    /// A scoped re-export starts from a copy of what is already there, because
    /// it rebuilds some days and promises to leave the rest (and the blog and
    /// CAPTIONS.txt) exactly as the last full export left them. `rebuilding`
    /// names the day folders to clear inside that copy; nil means a full export,
    /// which starts from nothing.
    static func begin(finalFolder: URL, rebuilding: Set<String>? = nil) throws -> ExportStaging {
        let fm = FileManager.default
        let parent = finalFolder.deletingLastPathComponent()
        // Inside the destination rather than the system temp folder, so the
        // swap at the end is a rename within one volume rather than a copy
        // across two, which is neither atomic nor free for a folder of reels.
        // Before claiming a new one, clear out any left by a run that died.
        sweepAbandoned(in: parent)
        let stagingRoot = parent.appendingPathComponent(stagingPrefix + UUID().uuidString)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        live.insert(stagingRoot)
        let working = stagingRoot.appendingPathComponent(finalFolder.lastPathComponent)

        do {
            if let rebuilding, fm.fileExists(atPath: finalFolder.path) {
                try fm.copyItem(at: finalFolder, to: working)
                // A re-export must not inherit anything from the previous one
                // for the days it is rebuilding: copyItem never overwrites, so
                // re-exported photos would keep stale content, and a trimmed
                // set leaves orphans (carousel 11.jpg after cutting to 10) that
                // would get uploaded.
                for folderName in rebuilding {
                    try? fm.removeItem(at: working.appendingPathComponent(folderName))
                }
            } else {
                try fm.createDirectory(at: working, withIntermediateDirectories: true)
            }
        } catch {
            live.remove(stagingRoot)
            try? fm.removeItem(at: stagingRoot)
            throw error
        }

        return ExportStaging(finalFolder: finalFolder, workingFolder: working,
                             stagingRoot: stagingRoot)
    }

    /// A swap that could not happen. Carries where the finished export is
    /// sitting instead, because the work really was done and telling somebody
    /// their export failed without saying where it is loses all of it.
    struct SwapFailure: Error, Equatable {
        let reason: String
        /// Where the finished export is sitting instead.
        let stagedAt: URL
        /// Set only when the previous export could not be put back either, so
        /// it is under this name rather than its own. Two folders in odd places
        /// is recoverable; not being told which is not.
        var previousExportAt: URL?
    }

    /// Put the staged export where it belongs.
    ///
    /// The previous export is moved aside first and only removed once the new
    /// one is verifiably in place, so a failure in the middle of the swap
    /// leaves one complete folder rather than none. A swap that cannot happen
    /// keeps BOTH: the previous export goes back where it was, and the staged
    /// one stays put and is named in the error.
    @discardableResult
    func commit() throws -> URL {
        let fm = FileManager.default
        var displaced: URL?
        if fm.fileExists(atPath: finalFolder.path) {
            // Unique rather than stamped: this name exists for the length of
            // one swap and is removed at the end of it, so it needs no clock
            // and makes no claim about when anything happened.
            let aside = finalFolder
                .appendingPathExtension("replaced-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: finalFolder, to: aside)
            } catch {
                throw SwapFailure(reason: error.localizedDescription, stagedAt: workingFolder)
            }
            displaced = aside
        }
        do {
            try fm.moveItem(at: workingFolder, to: finalFolder)
        } catch {
            // Put the previous export back rather than leaving the destination
            // with no export in it at all, and keep the staged one rather than
            // deleting the run's entire output because the last step failed.
            var previousExportAt: URL?
            if let displaced {
                do {
                    try fm.moveItem(at: displaced, to: finalFolder)
                } catch {
                    // Both folders are now under names nobody expects. Nothing
                    // is lost, but only if the message says where they are, so
                    // this failure is carried rather than discarded.
                    previousExportAt = displaced
                }
            }
            throw SwapFailure(reason: error.localizedDescription,
                              stagedAt: workingFolder,
                              previousExportAt: previousExportAt)
        }
        if let displaced { try? fm.removeItem(at: displaced) }
        Self.live.remove(stagingRoot)
        try? fm.removeItem(at: stagingRoot)
        return finalFolder
    }

    /// Throw the staged work away. The export already on disk is untouched.
    func abandon() {
        Self.live.remove(stagingRoot)
        try? FileManager.default.removeItem(at: stagingRoot)
    }
}

/// Which staging folders belong to a run that is still going.
///
/// Its own type with a lock because `ExportStaging.begin` runs off the main
/// actor (the text export is a detached task), and two exports starting at once
/// would otherwise race the set that decides what the sweep may delete.
private final class LiveStagingFolders: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    private func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func insert(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        paths.insert(key(url))
    }

    func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        paths.remove(key(url))
    }

    func contains(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.contains(key(url))
    }
}
