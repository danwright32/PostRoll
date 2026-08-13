import Foundation

/// Reclaims disk space by deleting files in the app's media folders (photos/,
/// audio/, programs/, clips/) that no event references any more. Photos are
/// copied into photos/ on import; programs are rasterised into programs/ (with
/// a retained source PDF and a baked program PDF); video clips are copied into
/// clips/ on import; when the event that used them is deleted, those copies
/// become orphans with nothing left to clean them up. This sweep is what
/// removes them.
///
/// Safety:
/// - Only ever deletes files *inside* photos/, audio/, programs/, and clips/.
/// - Never deletes a file still referenced by any event (collected across every
///   media field, so a photo shared between events survives). For programs/ this
///   includes the baked programPDFPath and each rasterised page's retained source
///   PDF, which is found by filename convention rather than a stored field.
/// - The caller MUST NOT run this when events.json failed to load (an empty or
///   partial events array would orphan, and delete, everything). AppState
///   guards on `EventStore.LoadResult.isAuthoritative`, which is true only when
///   the store was actually read.
enum OrphanedMediaCleanup {

    /// Deletes orphaned files and returns how many were removed.
    @discardableResult
    static func sweep(
        events: [Event],
        photosDir: URL = AppPaths.photosDir,
        audioDir: URL = AppPaths.audioDir,
        programsDir: URL = AppPaths.programsDir,
        clipsDir: URL = AppPaths.clipsDir
    ) -> Int {
        let referenced = referencedPaths(in: events)
        return [photosDir, audioDir, programsDir, clipsDir]
            .reduce(0) { $0 + removeOrphans(in: $1, referenced: referenced) }
    }

    /// Preview folders whose event no longer exists.
    ///
    /// Its own rule because `preview/` is a folder PER EVENT keyed by slug, not
    /// a flat directory of files, so the file sweep above cannot see it. Nothing
    /// else could either: the only code that ever deletes a preview folder is
    /// `ArchiveCleanup`, which iterates events still in the store, so a DELETED
    /// event's rendered reels, collages, story graphics and layout sidecars were
    /// reclaimed by nothing at all and leaked forever (#482, L38).
    ///
    /// Keyed on the slug rather than the id, because that is what the folder is
    /// named, and a live duplicate shares its original's slug: comparing against
    /// every live event's slug is what stops this deleting a folder another
    /// event is still using.
    ///
    /// Returns the folders removed, so the caller can say what happened rather
    /// than report a number that could mean anything.
    @discardableResult
    static func sweepPreviewFolders(
        events: [Event],
        previewDir: URL = AppPaths.previewDir
    ) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: previewDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let live = Set(events.map(ArchiveCleanup.slug(event:)))
        var removed: [String] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard !live.contains(entry.lastPathComponent) else { continue }
            do {
                try fm.removeItem(at: entry)
                removed.append(entry.lastPathComponent)
            } catch {
                // Named rather than swallowed: a folder that would not go is
                // disk this Mac has already been filled by once.
                NSLog("OrphanedMediaCleanup: could not remove preview folder \(entry.lastPathComponent): \(error)")
            }
        }
        return removed
    }

    /// Every on-disk media path any event points at, standardized for comparison.
    static func referencedPaths(in events: [Event]) -> Set<String> {
        var set: Set<String> = []
        func add(_ url: URL?) {
            guard let url else { return }
            set.insert(url.standardizedFileURL.path)
        }
        for event in events {
            event.blogPhotoPaths.forEach(add)
            event.programImagePaths.forEach(add)
            add(event.programPDFPath)
            // Retained source PDFs (<stem>.pdf) aren't stored in any field —
            // they're located from each rasterised page's filename — so protect
            // them explicitly or the sweep would delete a live event's source.
            for page in event.programImagePaths {
                if let source = ProgramPDFBuilder.sourcePDFPage(for: page) { add(source.pdfURL) }
            }
            for pd in event.days.values {
                pd.photoPaths.forEach(add)
                add(pd.screenRecordingPath)
                add(pd.rawPhotoPath)
                add(pd.editedPhotoPath)
                add(pd.bwPhotoPath)
                add(pd.audioPath)
                for cell in pd.collageCellOverride ?? [] {
                    add(URL(fileURLWithPath: cell.photoPath))
                }
                pd.clipPaths.forEach(add)
                for selection in pd.fridayClipPlan?.selections ?? [] {
                    add(URL(fileURLWithPath: selection.clipPath))
                }
                for override in pd.fridayClipOverride ?? [] {
                    add(URL(fileURLWithPath: override.clipPath))
                }
            }
        }
        return set
    }

    private static func removeOrphans(in dir: URL, referenced: Set<String>) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let dirPrefix = dir.standardizedFileURL.path + "/"
        var files = 0
        var orphans: [URL] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            files += 1
            let path = entry.standardizedFileURL.path
            // Constrain deletion to inside the target folder, belt and suspenders.
            guard path.hasPrefix(dirPrefix) else { continue }
            if !referenced.contains(path) { orphans.append(entry) }
        }

        // Sanity backstop: genuine orphans are a handful left behind by a deleted
        // event. If MOST of the folder looks unreferenced, the reference set is
        // almost certainly wrong (a path-encoding mismatch, a half-loaded events
        // array) rather than the library actually being orphaned — refuse to
        // delete and log, so a comparison bug can never wipe the user's photos.
        // (This is exactly what saved nothing the first time: a double-encoded
        // events.json made every photo look unreferenced.)
        if files >= 4, orphans.count * 2 > files {
            NSLog("OrphanedMediaCleanup: refusing to delete \(orphans.count)/\(files) files in "
                + "\(dir.lastPathComponent) — reference set looks wrong, skipping for safety.")
            return 0
        }

        var removed = 0
        for entry in orphans {
            try? fm.removeItem(at: entry)
            removed += 1
        }
        return removed
    }
}
