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

// MARK: - Save gate

/// Tracks store files that must not be written to.
///
/// A store whose bytes could not be read, or whose unreadable bytes could not
/// be moved aside, is still the only copy of every event, caption, blog draft,
/// OCR result and crop edit. Writing over it would destroy data precisely
/// because we could not read it. The block is keyed by path and is lifted the
/// moment a load proves that file readable again.
private final class SaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: Set<String> = []

    private func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func block(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        blocked.insert(key(url))
    }

    func unblock(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        blocked.remove(key(url))
    }

    func isBlocked(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked.contains(key(url))
    }
}

private let saveGate = SaveGate()

private extension NSError {
    /// True when the file simply is not there (a first launch), as opposed to
    /// being present but unreadable. `fileExists` cannot be used to tell these
    /// apart: it also returns false for a path the process is denied.
    var isFileNotFound: Bool {
        (domain == NSCocoaErrorDomain && code == NSFileReadNoSuchFileError)
            || (domain == NSPOSIXErrorDomain && code == Int(ENOENT))
    }
}

enum EventStore {
    static var storeURL: URL { AppPaths.eventsFile }

    /// Why a load did or did not produce the real event list.
    enum LoadStatus: Equatable {
        /// The store was read, or does not exist yet (a genuine empty list).
        case ok
        /// The bytes were read but are not valid event data. `setAsideAs` is the
        /// name the original was preserved under, or nil when that move failed.
        case corrupt(setAsideAs: String?)
        /// The file could not be read at all right now: a permission denial, an
        /// I/O error, a locked volume. Its contents are unknown and untouched.
        case unreadable
    }

    enum SaveOutcome: Equatable {
        case saved
        /// Refused, because writing would overwrite a store we could not read.
        case blocked
        case failed(String)
    }

    struct LoadResult {
        var events: [Event]
        var status: LoadStatus
        /// User facing explanation, set for every status other than `.ok`.
        var recoveryMessage: String?

        /// True only when `events` is the complete, real contents of the store.
        /// Everything that deletes files or rewrites the store on the strength
        /// of this list must check this first: an empty list we arrived at by
        /// failing to read is not permission to delete anything.
        var isAuthoritative: Bool { status == .ok }
    }

    /// System error text already ends in a period, so it cannot simply be
    /// dropped into the middle of a sentence.
    static func unreadableMessage(_ error: Error) -> String {
        let reason = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "PostRoll could not read your saved events: \(reason). Nothing was changed or deleted, and nothing new will be saved until the file can be read again."
    }

    // load/save take the URL as a parameter (defaulting to the real store)
    // so tests can exercise the recovery and backup paths against a temp
    // directory without ever touching live data.

    static func load(from url: URL = storeURL) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.isFileNotFound {
            saveGate.unblock(url)
            return LoadResult(events: [], status: .ok, recoveryMessage: nil)
        } catch {
            // Unknown contents, not invalid contents. Leave the file exactly
            // where it is and refuse to write over it.
            NSLog("EventStore: could not read \(url.lastPathComponent): \(error)")
            saveGate.block(url)
            return LoadResult(
                events: [],
                status: .unreadable,
                recoveryMessage: unreadableMessage(error)
            )
        }

        do {
            let events = try JSONDecoder().decode([Event].self, from: data)
            saveGate.unblock(url)
            return LoadResult(events: events, status: .ok, recoveryMessage: nil)
        } catch let error as DecodingError {
            // Genuine corruption: the bytes are there and they are not events.
            NSLog("EventStore: failed to decode \(url.lastPathComponent): \(error)")
            let folder = url.deletingLastPathComponent().path
            guard let backup = StoreRecovery.setAside(url) else {
                // The original could not be preserved, so it is still the only
                // copy. Saving now would erode it one generation at a time.
                saveGate.block(url)
                return LoadResult(
                    events: [],
                    status: .corrupt(setAsideAs: nil),
                    recoveryMessage: "Your saved events could not be read, and the unreadable file could not be moved to safety either. Nothing was deleted, and nothing will be saved over it. The file is \(url.lastPathComponent) in \(folder)."
                )
            }
            saveGate.unblock(url)
            return LoadResult(
                events: [],
                status: .corrupt(setAsideAs: backup.lastPathComponent),
                recoveryMessage: "Your saved events could not be read, so PostRoll is starting with an empty list. Nothing was deleted: the unreadable file was set aside as \(backup.lastPathComponent) in \(folder)."
            )
        } catch {
            // Not a decode failure, so we have no evidence the file is bad.
            // Never rename on an error we do not understand.
            NSLog("EventStore: unexpected failure reading \(url.lastPathComponent): \(error)")
            saveGate.block(url)
            return LoadResult(
                events: [],
                status: .unreadable,
                recoveryMessage: unreadableMessage(error)
            )
        }
    }

    /// True when saving to this store is currently refused, because the last
    /// load could not read it.
    static func savesAreBlocked(for url: URL = storeURL) -> Bool {
        saveGate.isBlocked(url)
    }

    @discardableResult
    static func save(_ events: [Event], to url: URL = storeURL) -> SaveOutcome {
        guard !saveGate.isBlocked(url) else {
            NSLog("EventStore: refusing to save; \(url.lastPathComponent) could not be read and must not be overwritten")
            return .blocked
        }
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
            return .saved
        } catch {
            NSLog("EventStore: failed to save \(url.lastPathComponent): \(error)")
            return .failed(error.localizedDescription)
        }
    }
}
