import Foundation

/// Shared check for whether a referenced media file has gone missing from disk
/// (set, but the file no longer exists). Used to flag missing reel audio the way
/// photos are flagged when their files are moved or deleted.
enum MediaPresence {
    /// True only when `url` is set AND its file is absent. An unset (nil) URL is
    /// not "missing" — there's simply nothing referenced.
    static func isMissing(_ url: URL?, fileManager fm: FileManager = .default) -> Bool {
        guard let url else { return false }
        return !fm.fileExists(atPath: url.path)
    }
}
