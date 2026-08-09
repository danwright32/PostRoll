import Foundation

/// A bounded ring of verified-good backups for a JSON store (#102, #88).
///
/// What this replaces: one `.bak` slot, copied from whatever happened to be on
/// disk. Save runs on every edit, so ordinary typing erased the only backup
/// long before Dan could notice a problem, and because the copy was taken
/// without looking at the file, a degraded store became the backup. The safety
/// net could therefore be destroyed by exactly the failure it existed for.
///
/// Two rules follow, and both are the point:
///
/// 1. **Only a file that decodes is ever captured.** A backup taken from a bad
///    file is worse than no backup, because it looks like protection.
/// 2. **Several generations are kept.** One slot cannot survive two bad states
///    in a row, and problems are usually noticed a few saves late.
///
/// Used by both events.json and analytics.json rather than each store growing
/// its own version.
enum StoreBackups {

    /// How many generations to keep per store.
    static let defaultKeep = 5

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// `events.json` -> `events.json.20260808-211500.bak`
    private static func prefix(for store: URL) -> String {
        store.lastPathComponent + "."
    }

    /// Every backup belonging to `store`, oldest first.
    ///
    /// Sorted by filename, which sorts chronologically because the stamp is
    /// fixed-width and big-endian. Never by modification date, which a copy or
    /// a restore can rewrite.
    static func existing(for store: URL) -> [URL] {
        let dir = store.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix(for: store)) && $0.hasSuffix(".bak") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// The most recent backup, for a restore.
    static func newest(for store: URL) -> URL? { existing(for: store).last }

    /// Capture the current contents of `store` as a backup, then prune.
    ///
    /// Call BEFORE overwriting the store. Does nothing when the file is
    /// missing, empty, or fails `isValid`, so a bad state can never displace a
    /// good backup.
    ///
    /// `now` is injected so the naming is testable without waiting on the clock.
    static func rotate(store: URL,
                       keeping: Int = defaultKeep,
                       isValid: (Data) -> Bool,
                       now: () -> Date = Date.init) {
        guard let data = try? Data(contentsOf: store), !data.isEmpty else { return }
        guard isValid(data) else {
            NSLog("StoreBackups: \(store.lastPathComponent) does not decode, so it was NOT backed up; existing backups kept.")
            return
        }

        let dir = store.deletingLastPathComponent()
        let base = prefix(for: store) + stamp.string(from: now())
        // Two saves inside one second must not collide: without this the second
        // silently overwrites the first, quietly costing a generation.
        var candidate = dir.appendingPathComponent(base + ".bak")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(suffix).bak")
            suffix += 1
        }

        do {
            try data.write(to: candidate, options: .atomic)
        } catch {
            NSLog("StoreBackups: could not write \(candidate.lastPathComponent): \(error)")
            return
        }
        prune(for: store, keeping: keeping)
    }

    /// Drop the oldest backups beyond `keeping`.
    static func prune(for store: URL, keeping: Int = defaultKeep) {
        let all = existing(for: store)
        guard all.count > keeping else { return }
        for url in all.prefix(all.count - keeping) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
