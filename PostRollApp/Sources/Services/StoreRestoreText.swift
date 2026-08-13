import Foundation

/// What the corrupt-store alert says, and what its Restore button says back
/// (#441).
///
/// Out of the view so the wording can be pinned by a test, for the same reason
/// the other store messages are: each of these sentences is a promise about
/// what the code did with a file that holds every caption, blog and crop edit
/// Dan owns, and a promise nothing checks is the one that drifts.

/// A backup the app can offer to put back.
struct RestorableBackup: Equatable {
    let fileName: String
    /// When it was taken, or nil when the filename does not carry a readable
    /// stamp. Nil is shown as the filename rather than as a guessed date.
    let takenAt: Date?
}

enum StoreRestoreText {

    /// The label on the button that puts a backup back.
    static let restoreLabel = "Restore Latest Backup"

    /// How a backup's date reads to a person. Local time, because the person
    /// reading it is deciding whether it predates the work they are missing,
    /// and the UTC stamp in the filename cannot be compared with their memory
    /// of this morning.
    private static let readable: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func describe(_ backup: RestorableBackup) -> String {
        guard let takenAt = backup.takenAt else { return backup.fileName }
        return readable.string(from: takenAt)
    }

    /// The whole message for a store that was read and turned out not to be
    /// event data.
    ///
    /// The offer is part of the message, not only a button: a button whose
    /// consequence is not stated is one nobody presses when the consequence is
    /// "replace everything I can see".
    static func corruptStore(_ reason: String?,
                             offering backup: RestorableBackup?) -> String? {
        guard let reason else { return nil }
        guard let backup else {
            return reason + " There is no earlier backup to put back."
        }
        return reason
            + " A copy saved on \(describe(backup)) can be put back, replacing what is "
            + "on screen now."
    }

    /// The button was pressed and there was nothing to restore. Only reachable
    /// when the backups went away between the load and the press, so it says
    /// what is true now rather than repeating the offer.
    static let noBackup =
        "There is no backup to put back. Nothing was changed, and the file that could "
        + "not be read is still set aside."

    static func failed(_ reason: String) -> String {
        "The backup could not be put back: \(Sentence.closed(reason)) Nothing was "
        + "changed, and the file that could not be read is still set aside."
    }
}
