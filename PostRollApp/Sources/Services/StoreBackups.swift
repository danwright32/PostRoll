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

    /// One clock for every stamped file belonging to a store: its backups AND
    /// the `.corrupt-` copy `StoreRecovery` sets aside. They are compared
    /// against each other to decide which backups predate a corruption, and a
    /// stamp written in local time cannot be compared with one written in UTC
    /// (L39). One formatter rather than two makes that comparison sound by
    /// construction instead of by everyone remembering.
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The fixed width of one stamp, so a collision-suffixed backup
    /// (`...-211500-1.bak`) still yields the field the comparison needs.
    private static let stampWidth = "yyyyMMdd-HHmmss".count

    /// The extension `StoreRecovery` gives a store it moves out of the way.
    static let corruptMarker = "corrupt-"

    /// `events.json` -> `events.json.20260808-211500.bak`
    private static func prefix(for store: URL) -> String {
        store.lastPathComponent + "."
    }

    /// The stamp inside one stamped filename belonging to `store`, or nil when
    /// the name is not shaped like one.
    private static func stampField(of name: String, for store: URL) -> String? {
        let p = prefix(for: store)
        guard name.hasPrefix(p) else { return nil }
        let rest = name.dropFirst(p.count)
            .replacingOccurrences(of: corruptMarker, with: "")
        guard rest.count >= stampWidth else { return nil }
        return String(rest.prefix(stampWidth))
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

    /// The most recent backup, whatever it holds.
    static func newest(for store: URL) -> URL? { existing(for: store).last }

    /// When the store was last found corrupt and set aside, as a stamp, or nil
    /// when that has never happened to this store.
    ///
    /// Read off the `.corrupt-` files on disk rather than remembered in memory,
    /// so the protection below survives the relaunch that usually follows a
    /// corruption. An in-memory flag would be gone by the second launch, which
    /// is exactly when ordinary saves start eating the generations.
    static func lastCorruptionStamp(for store: URL) -> String? {
        let dir = store.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix(for: store) + corruptMarker) }
            .compactMap { stampField(of: $0, for: store) }
            .max()
    }

    /// The backups taken BEFORE the store was last found corrupt.
    ///
    /// These are the only copies of what was lost, and they must survive
    /// ordinary use: the near-empty store the app starts with after a
    /// corruption rotates its own perfectly valid backups on every save, and
    /// five of those would otherwise push all five good generations out of the
    /// ring within five saves, destroying the safety net during the one window
    /// it exists for.
    static func protected(for store: URL) -> [URL] {
        guard let cutoff = lastCorruptionStamp(for: store) else { return [] }
        return existing(for: store).filter {
            guard let stamp = stampField(of: $0.lastPathComponent, for: store) else { return false }
            return stamp <= cutoff
        }
    }

    /// The backup a restore should offer.
    ///
    /// After a corruption this is the newest backup taken before it, never the
    /// newest overall: the newest overall is a copy of the empty store the
    /// person is trying to undo, and restoring it would look like the button
    /// worked while putting the emptiness back.
    static func restorable(for store: URL) -> URL? {
        if lastCorruptionStamp(for: store) != nil { return protected(for: store).last }
        return newest(for: store)
    }

    /// When a backup was taken, for saying so on screen.
    static func takenAt(_ backup: URL, of store: URL) -> Date? {
        stampField(of: backup.lastPathComponent, for: store).flatMap(stamp.date(from:))
    }

    /// What a restore did.
    enum RestoreOutcome: Equatable {
        /// The store now holds the contents of this backup.
        case restored(from: String)
        /// There is no backup to put back.
        case noBackup
        /// Nothing was changed. The reason is for the person, not the log.
        case failed(String)
    }

    /// Put the newest good backup of `store` back in place.
    ///
    /// Three rules, and each is a way this could destroy data instead of
    /// recovering it:
    ///
    /// 1. The backup is decoded BEFORE anything is written, so a restore can
    ///    never replace one unreadable file with another.
    /// 2. Whatever is currently at `store` is moved aside first, never deleted,
    ///    because the person may have entered work into the empty store since
    ///    the corruption (L5).
    /// 3. A failure at any step leaves the store exactly as it was and says so,
    ///    rather than reporting a restore that did not happen.
    static func restore(store: URL,
                        isValid: (Data) -> Bool,
                        now: () -> Date = Date.init) -> RestoreOutcome {
        guard let source = restorable(for: store) else { return .noBackup }

        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard isValid(data) else {
            return .failed("\(source.lastPathComponent) could not be read as saved data.")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: store.path) {
            let kept = store.appendingPathExtension("replaced-\(stamp.string(from: now()))")
            do {
                try fm.moveItem(at: store, to: kept)
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        do {
            try data.write(to: store, options: .atomic)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .restored(from: source.lastPathComponent)
    }

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

    /// Drop the oldest backups beyond `keeping`, except the pre-corruption
    /// generations, which are never pruned while the store they belong to has
    /// been set aside as corrupt.
    static func prune(for store: URL, keeping: Int = defaultKeep) {
        let untouchable = Set(protected(for: store).map(\.lastPathComponent))
        let prunable = existing(for: store).filter { !untouchable.contains($0.lastPathComponent) }
        guard prunable.count > keeping else { return }
        for url in prunable.prefix(prunable.count - keeping) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
