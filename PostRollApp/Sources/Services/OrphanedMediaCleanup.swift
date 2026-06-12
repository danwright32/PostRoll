import Foundation

/// Reclaims disk space by deleting files in the app's media folders (photos/,
/// audio/) that no event references any more. Photos are copied into photos/ on
/// import; when the event that used them is deleted, those copies become
/// orphans with nothing left to clean them up. This sweep is what removes them.
///
/// Safety:
/// - Only ever deletes files *inside* photos/ and audio/.
/// - Never deletes a file still referenced by any event (collected across every
///   media field, so a photo shared between events survives).
/// - The caller MUST NOT run this when events.json failed to load (an empty or
///   partial events array would orphan — and delete — everything). AppState
///   guards on `dataLoadWarning == nil`.
enum OrphanedMediaCleanup {

    /// Deletes orphaned files and returns how many were removed.
    @discardableResult
    static func sweep(
        events: [Event],
        photosDir: URL = AppPaths.photosDir,
        audioDir: URL = AppPaths.audioDir
    ) -> Int {
        let referenced = referencedPaths(in: events)
        return [photosDir, audioDir].reduce(0) { $0 + removeOrphans(in: $1, referenced: referenced) }
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
        var removed = 0
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            let path = entry.standardizedFileURL.path
            // Constrain deletion to inside the target folder, belt and suspenders.
            guard path.hasPrefix(dirPrefix) else { continue }
            guard !referenced.contains(path) else { continue }
            try? fm.removeItem(at: entry)
            removed += 1
        }
        return removed
    }
}
