import Foundation

/// Reclaims the per-event progress files left behind by deleted events (#235).
///
/// Every generation run writes the step it is on to
/// `AppPaths.progressFile(forEventID:)`, and the file is deliberately left in
/// place afterwards so a finished run's last step and a dead run's final step
/// are both still readable. Nothing ever deleted one, so removing an event left
/// its file on disk permanently. The files are tiny; this is housekeeping
/// rather than a space problem, and the point is that the app has one answer to
/// who clears up per-event scratch files rather than none.
///
/// Safety, the same shape as `OrphanedMediaCleanup`:
/// - Only ever deletes files directly inside the progress directory, and only
///   ones named `<uuid>.json`, which is the name this app writes. Anything else
///   in there was put there by something else and is left alone.
/// - The caller MUST NOT run this when events.json failed to load. An empty or
///   partial events array would make every file an orphan. `AppState` guards on
///   `EventStore.LoadResult.isAuthoritative`.
enum ProgressFileCleanup {

    /// Deletes progress files belonging to no event, returning their names.
    ///
    /// Names rather than a count, so a sweep that reached the wrong file leaves
    /// a record of which one instead of a number that could mean anything.
    @discardableResult
    static func sweep(events: [Event],
                      progressDir: URL = AppPaths.progressDir) -> [String] {
        let live = Set(events.map(\.id))
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: progressDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var removed: [String] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true,
                  entry.pathExtension == "json",
                  let id = eventID(fromFileNamed: entry.deletingPathExtension().lastPathComponent),
                  !live.contains(id)
            else { continue }
            guard (try? fm.removeItem(at: entry)) != nil else { continue }
            removed.append(entry.lastPathComponent)
        }
        return removed.sorted()
    }

    /// The event a progress file belongs to, or nil when the name is not ours.
    ///
    /// One name per run, because the runs report separately and overlap in
    /// time. The suffixes are DERIVED from `AppPaths.progressRunSuffixes`, the
    /// same list the writers build their paths from, rather than spelled out
    /// here as well (#1128, L41).
    ///
    /// They were spelled out here, and had already drifted: this knew
    /// `<uuid>.json` and `<uuid>-media.json`, while `ocrProgressFile` has
    /// written `<uuid>-ocr.json` since #467. Every OCR progress file of every
    /// deleted event was left behind forever, which is the exact defect this
    /// file exists to fix, reintroduced by the one mechanism it could not see.
    static func eventID(fromFileNamed stem: String) -> UUID? {
        for suffix in AppPaths.progressRunSuffixes where !suffix.isEmpty {
            guard stem.hasSuffix(suffix) else { continue }
            if let id = UUID(uuidString: String(stem.dropLast(suffix.count))) { return id }
        }
        return UUID(uuidString: stem)
    }
}
