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
}
