import Foundation

/// Copies any event media still referenced from outside the app's own storage
/// (e.g. an original picked from ~/Downloads or ~/Desktop) into
/// `AppPaths.photosDir` / `audioDir`, then rewrites the stored paths to point at
/// the in-storage copy.
///
/// macOS gates ~/Downloads and ~/Desktop per app launch, so any view that reads
/// an original path on every interaction (the Wednesday collage editor reloads a
/// cell's image on each drag) re-triggers the permission prompt. Once the file
/// lives inside the app's folder those reads are ungated.
///
/// Idempotent: a path already inside app storage is left untouched, and a file
/// that no longer exists on disk keeps its old path (the missing-photo flow
/// handles those separately). Runs once at launch and persists only if it moved
/// something, so the second launch is a no-op.
enum MediaReclaim {

    @discardableResult
    static func reclaim(
        events: inout [Event],
        photosDir: URL = AppPaths.photosDir,
        audioDir: URL = AppPaths.audioDir,
        storageRoot: URL = AppPaths.root
    ) -> Bool {
        var changed = false
        for i in events.indices {
            if reclaim(event: &events[i], photosDir: photosDir, audioDir: audioDir, storageRoot: storageRoot) {
                changed = true
            }
        }
        return changed
    }

    private static func reclaim(
        event: inout Event, photosDir: URL, audioDir: URL, storageRoot: URL
    ) -> Bool {
        var changed = false

        let newBlog = event.blogPhotoPaths.map { stored($0, into: photosDir, storageRoot: storageRoot) }
        if newBlog != event.blogPhotoPaths { event.blogPhotoPaths = newBlog; changed = true }

        for key in event.days.keys {
            guard var pd = event.days[key] else { continue }
            if reclaim(day: &pd, photosDir: photosDir, audioDir: audioDir, storageRoot: storageRoot) {
                event.days[key] = pd
                changed = true
            }
        }
        return changed
    }

    private static func reclaim(
        day pd: inout PostingDay, photosDir: URL, audioDir: URL, storageRoot: URL
    ) -> Bool {
        var changed = false

        // photoPaths carry per-photo crops, tags, and collage cells. rebinding
        // moves all of them to the new URL in one pass so nothing is orphaned.
        var remap: [URL: URL] = [:]
        for url in pd.photoPaths {
            let dest = stored(url, into: photosDir, storageRoot: storageRoot)
            if dest != url { remap[url] = dest }
        }
        if !remap.isEmpty {
            pd = pd.rebindingPhotos(remap)
            changed = true
        }

        // Standalone Tuesday/Thursday media fields, photos and video into the
        // photos dir (matching the file picker) and audio into the audio dir.
        func move(_ url: inout URL?, into dir: URL) {
            guard let current = url else { return }
            let dest = stored(current, into: dir, storageRoot: storageRoot)
            if dest != current { url = dest; changed = true }
        }
        move(&pd.screenRecordingPath, into: photosDir)
        move(&pd.rawPhotoPath, into: photosDir)
        move(&pd.editedPhotoPath, into: photosDir)
        move(&pd.bwPhotoPath, into: photosDir)
        move(&pd.audioPath, into: audioDir)

        return changed
    }

    /// In-storage copy of `url`, or `url` unchanged when it already lives inside
    /// app storage or the copy fails (e.g. the original file is gone).
    private static func stored(_ url: URL, into dir: URL, storageRoot: URL) -> URL {
        AppPaths.importedCopy(of: url, into: dir, storageRoot: storageRoot) ?? url
    }
}
