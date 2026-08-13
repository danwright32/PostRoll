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
        let stagingRoot = parent.appendingPathComponent(".postroll-export-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
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
        try? fm.removeItem(at: stagingRoot)
        return finalFolder
    }

    /// Throw the staged work away. The export already on disk is untouched.
    func abandon() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }
}
