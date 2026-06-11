import Foundation

// MARK: - Store recovery

/// Moves an undecodable store file aside so the next save cannot silently
/// overwrite it. Returns the backup URL, or nil if the move failed.
enum StoreRecovery {
    @discardableResult
    static func setAside(_ url: URL) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url.appendingPathExtension("corrupt-\(f.string(from: Date()))")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup
        } catch {
            NSLog("StoreRecovery: could not set aside \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}

enum EventStore {
    static var storeURL: URL { AppPaths.eventsFile }

    struct LoadResult {
        var events: [Event]
        /// Non nil when the file existed but could not be decoded. The
        /// unreadable file has already been moved aside for recovery.
        var recoveryMessage: String?
    }

    // load/save take the URL as a parameter (defaulting to the real store)
    // so tests can exercise the recovery and backup paths against a temp
    // directory without ever touching live data.

    static func load(from url: URL = storeURL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadResult(events: [], recoveryMessage: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let events = try JSONDecoder().decode([Event].self, from: data)
            return LoadResult(events: events, recoveryMessage: nil)
        } catch {
            // A file that exists but fails to decode must never be treated as
            // empty: the next save would overwrite it and destroy every event.
            NSLog("EventStore: failed to decode events.json: \(error)")
            let backup = StoreRecovery.setAside(url)
            let name = backup?.lastPathComponent ?? "events.json"
            return LoadResult(
                events: [],
                recoveryMessage: "Your saved events could not be read, so PostRoll is starting with an empty list. Nothing was deleted: the unreadable file was set aside as \(name) in Documents/PostRoll."
            )
        }
    }

    static func save(_ events: [Event], to url: URL = storeURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(events)
            // Keep the previous generation as .bak before overwriting:
            // events.json is the single copy of every caption, blog, OCR
            // result, and crop edit. On APFS this copy is a clone, so the
            // cost is negligible even though save runs on every edit.
            if FileManager.default.fileExists(atPath: url.path) {
                let backup = url.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("EventStore: failed to save events.json: \(error)")
        }
    }
}
