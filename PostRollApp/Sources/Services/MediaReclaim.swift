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
/// something, so the second launch writes nothing.
///
/// It used to say the second launch was "a no-op", and on real data that was
/// false (#971, L32). A path whose file is gone kept its path, correctly, and
/// was then RE-ATTEMPTED on every launch: measured 2026-08-29, 1,514 of them,
/// each costing a directory creation, a destination check, a doomed copy and a
/// log line, on the main thread before the first frame. `AppPaths` now refuses
/// a source that is not there before doing any of that, so what is left per
/// dead reference is one existence check.
///
/// How many it could not reach is REPORTED rather than swallowed. A repair that
/// can never succeed, retried forever and saying nothing, is indistinguishable
/// from one with nothing to do (L98, L47).
enum MediaReclaim {

    /// What one pass did.
    ///
    /// A value rather than a bare Bool, because "did anything move" and "how
    /// many references point at nothing" are different questions and the second
    /// had no answer anywhere.
    struct Outcome: Equatable {
        /// Something moved, so the store is worth persisting.
        var changed = false
        /// Stored paths whose file is not on disk. Not an error: `~/Downloads`
        /// is a working folder and a file can come back, which is why nothing
        /// here writes a permanent give-up mark.
        var unreachable = 0
    }

    @discardableResult
    static func reclaim(
        events: inout [Event],
        photosDir: URL = AppPaths.photosDir,
        audioDir: URL = AppPaths.audioDir,
        clipsDir: URL = AppPaths.clipsDir,
        storageRoot: URL = AppPaths.root
    ) -> Outcome {
        var outcome = Outcome()
        for i in events.indices {
            if reclaim(event: &events[i], photosDir: photosDir, audioDir: audioDir,
                       clipsDir: clipsDir, storageRoot: storageRoot,
                       unreachable: &outcome.unreachable) {
                outcome.changed = true
            }
        }
        return outcome
    }

    // The count is threaded through rather than kept in a static. A shared
    // mutable counter is not concurrency safe, and a pass that read one would
    // report whatever another pass had left in it (L205).
    private static func reclaim(
        event: inout Event, photosDir: URL, audioDir: URL, clipsDir: URL,
        storageRoot: URL, unreachable: inout Int
    ) -> Bool {
        var changed = false

        var seen = unreachable
        let newBlog = event.blogPhotoPaths.map {
            stored($0, into: photosDir, storageRoot: storageRoot, unreachable: &seen)
        }
        unreachable = seen
        if newBlog != event.blogPhotoPaths { event.blogPhotoPaths = newBlog; changed = true }

        for key in event.days.keys {
            guard var pd = event.days[key] else { continue }
            if reclaim(day: &pd, photosDir: photosDir, audioDir: audioDir,
                       clipsDir: clipsDir, storageRoot: storageRoot,
                       unreachable: &unreachable) {
                event.days[key] = pd
                changed = true
            }
        }
        return changed
    }

    private static func reclaim(
        day pd: inout PostingDay, photosDir: URL, audioDir: URL, clipsDir: URL,
        storageRoot: URL, unreachable: inout Int
    ) -> Bool {
        var changed = false

        // photoPaths carry per-photo crops, tags, and collage cells. rebinding
        // moves all of them to the new URL in one pass so nothing is orphaned.
        var remap: [URL: URL] = [:]
        for url in pd.photoPaths {
            let dest = stored(url, into: photosDir, storageRoot: storageRoot,
                              unreachable: &unreachable)
            if dest != url { remap[url] = dest }
        }
        if !remap.isEmpty {
            pd = pd.rebindingPhotos(remap)
            changed = true
        }

        // clipPaths carry the AI plan and user override entries, mirroring
        // photoPaths above. rebindingClips moves both to the new URL.
        var clipRemap: [URL: URL] = [:]
        for url in pd.clipPaths {
            let dest = stored(url, into: clipsDir, storageRoot: storageRoot,
                              unreachable: &unreachable)
            if dest != url { clipRemap[url] = dest }
        }
        if !clipRemap.isEmpty {
            pd = pd.rebindingClips(clipRemap)
            changed = true
        }

        // Standalone Tuesday/Thursday media fields, photos and video into the
        // photos dir (matching the file picker) and audio into the audio dir.
        var missing = unreachable
        func move(_ url: inout URL?, into dir: URL) {
            guard let current = url else { return }
            let dest = stored(current, into: dir, storageRoot: storageRoot,
                              unreachable: &missing)
            if dest != current { url = dest; changed = true }
        }
        move(&pd.screenRecordingPath, into: photosDir)
        move(&pd.rawPhotoPath, into: photosDir)
        move(&pd.editedPhotoPath, into: photosDir)
        move(&pd.bwPhotoPath, into: photosDir)
        move(&pd.audioPath, into: audioDir)
        unreachable = missing

        return changed
    }

    /// In-storage copy of `url`, or `url` unchanged when it already lives inside
    /// app storage or the copy fails (e.g. the original file is gone).
    private static func stored(_ url: URL, into dir: URL, storageRoot: URL,
                               unreachable: inout Int) -> URL {
        switch AppPaths.importedCopyResult(of: url, into: dir, storageRoot: storageRoot) {
        case .success(let moved):
            return moved
        case .failure(let why):
            // A file that is gone keeps its path for the missing-media flow,
            // and is COUNTED so the pass can say what it could not reach. A
            // real copy failure keeps its path too, but is not counted here:
            // that is a different problem with a different remedy (L11).
            if why.sourceIsMissing { unreachable += 1 }
            return url
        }
    }
}
