import Foundation

/// Single source of truth for where PostRoll keeps its data on disk.
///
/// The root defaults to ~/Documents/PostRoll, which is also the Python
/// project checkout. Tests and UI automation can redirect everything by
/// setting POSTROLL_DATA_DIR in the environment before launch, so no test
/// run can ever touch live data.
enum AppPaths {
    static let root: URL = resolveRoot()

    /// Split out so tests can exercise the override logic with an injected
    /// environment; the static `root` resolves once per process.
    static func resolveRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["POSTROLL_DATA_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/PostRoll")
    }

    static var eventsFile: URL { root.appendingPathComponent("events.json") }
    static var analyticsFile: URL { root.appendingPathComponent("analytics.json") }
    static var programsDir: URL { root.appendingPathComponent("programs") }
    static var photosDir: URL { root.appendingPathComponent("photos") }
    static var audioDir: URL { root.appendingPathComponent("audio") }

    /// True when `url` already lives under `storageRoot`.
    static func isInside(_ url: URL, root storageRoot: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(storageRoot.standardizedFileURL.path + "/")
    }

    /// True when `url` already lives inside the app's own storage.
    static func isInsideAppStorage(_ url: URL) -> Bool { isInside(url, root: root) }

    /// Copies an external file into `dir` (inside the app's storage) and returns
    /// the new URL. Files the user picks from ~/Downloads, ~/Desktop, etc. are
    /// gated by macOS per app launch; copying them into the app's own folder
    /// means later reads (thumbnails, export) don't re-trigger that permission
    /// prompt. Names are uniquified so two different files can't collide.
    /// Returns `url` unchanged when it is already inside app storage, or nil on
    /// copy failure. `storageRoot` is injectable so tests can run against a
    /// temporary tree.
    static func importedCopy(of url: URL, into dir: URL, storageRoot: URL = AppPaths.root) -> URL? {
        if isInside(url, root: storageRoot) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
            dest = dir.appendingPathComponent("\(stem)_\(UUID().uuidString.prefix(8)).\(ext)")
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            NSLog("AppPaths.importedCopy failed for \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}
