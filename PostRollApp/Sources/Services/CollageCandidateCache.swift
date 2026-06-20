import Foundation

/// Caches rendered collage layout candidates per day so reopening the layout
/// gallery is instant and shows the SAME options (issue #61), and so the temp
/// directories they live in get cleaned up instead of accumulating (issue #60).
///
/// Keyed by day. Each day holds at most one candidate set; storing a new set
/// for a day deletes the previous set's temp directory. This bounds the temp
/// footprint to one directory per collage day rather than one per gallery open.
@MainActor
final class CollageCandidateCache {
    static let shared = CollageCandidateCache()

    private struct Entry {
        let fingerprint: String
        let candidates: [CollageCandidate]
    }

    private var entries: [String: Entry] = [:]   // keyed by day.rawValue

    /// Cached candidates for `day` when the fingerprint matches and the files
    /// are still on disk (the OS may have cleared the temp dir). Otherwise nil.
    func cached(day: DayName, fingerprint: String) -> [CollageCandidate]? {
        guard let entry = entries[day.rawValue], entry.fingerprint == fingerprint else { return nil }
        guard entry.candidates.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            remove(day: day)
            return nil
        }
        return entry.candidates
    }

    /// Store a freshly rendered set, deleting the day's previous set's directory.
    func store(day: DayName, fingerprint: String, candidates: [CollageCandidate]) {
        removeDirectory(for: entries[day.rawValue]?.candidates)
        entries[day.rawValue] = Entry(fingerprint: fingerprint, candidates: candidates)
    }

    /// Drop a day's cached set and remove its temp directory.
    func remove(day: DayName) {
        removeDirectory(for: entries[day.rawValue]?.candidates)
        entries.removeValue(forKey: day.rawValue)
    }

    private func removeDirectory(for candidates: [CollageCandidate]?) {
        // All candidates for a render share one parent temp directory.
        guard let first = candidates?.first else { return }
        let dir = URL(fileURLWithPath: first.path).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }
}
