import Foundation

/// The refuse-to-overwrite-what-we-could-not-read rule, in one place (#439).
///
/// Three stores need it and each had grown its own version. EventStore had the
/// whole thing, AccountBook had the classification but its own inline copy of
/// it, and AnalyticsStore had neither: a file it failed to READ was renamed as
/// though it were corrupt, and if that rename also failed the very first save
/// wrote over bytes nobody had managed to read. That is the worst of the three
/// files to lose, since rebuilding analytics.json means re-exporting from Meta.
///
/// One implementation rather than three, because this is a rule about data
/// safety and a rule with three implementations has three behaviours.

/// What a save did.
///
/// `blocked` is not a failure to fix, it is the gate working: the store is intact
/// and deliberately untouched. `failed` is a write that was attempted and did not
/// land, which is the one a person has to be told about.
enum StoreSaveOutcome: Equatable {
    case saved
    /// Refused, because writing would overwrite a store we could not read.
    case blocked
    case failed(String)
}

extension NSError {
    /// True when the file simply is not there (a first launch), as opposed to
    /// being present but unreadable.
    ///
    /// `FileManager.fileExists` cannot be used to tell those apart: it also
    /// returns false for a path the process is denied, so under a TCC refusal it
    /// reports a first launch and the app starts empty over live data. Only the
    /// error from the read itself distinguishes them.
    var isFileNotFound: Bool {
        (domain == NSCocoaErrorDomain && code == NSFileReadNoSuchFileError)
            || (domain == NSPOSIXErrorDomain && code == Int(ENOENT))
    }
}

/// Tracks store files that must not be written to.
///
/// A store whose bytes could not be read, or whose unreadable bytes could not be
/// moved aside, is still the only copy of what it holds. Writing over it would
/// destroy that data precisely because we could not read it. The block is keyed
/// by path and is lifted the moment a load proves that file readable again.
final class StoreSaveGate: @unchecked Sendable {

    /// One gate for the whole app, keyed by path, so a store that is loaded from
    /// several places (EventStore is a static enum, AnalyticsStore an instance)
    /// cannot end up with one copy blocked and another not.
    static let shared = StoreSaveGate()

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

/// The words for a store that could not be read at all.
///
/// Shared for the same reason the gate is: both messages have to promise exactly
/// what the gate actually does, and two copies drift into one of them promising
/// something the code stopped doing. The reason goes through `Sentence` because
/// a system error already ends in a stop and a decoding error does not.
enum StoreRecoveryText {
    static func unreadable(_ subject: String, _ error: Error) -> String {
        let reason = Sentence.closed(error.localizedDescription)
        return "\(subject) could not be read: \(reason) Nothing was changed or deleted, "
             + "and nothing new will be saved until the file can be read again."
    }
}
