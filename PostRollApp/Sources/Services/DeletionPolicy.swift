import Foundation

/// Deleting an event is offered with an Undo, so for a few seconds after the
/// delete the event is out of the list but is not gone: taking the Undo has to
/// bring back a working event, photos included.
///
/// `OrphanedMediaCleanup` decides what to delete purely from the events it is
/// handed, so the whole rule lives here: an event still inside its undo window
/// is handed to the sweep alongside the live list, and therefore keeps its
/// files. Everything else orphaned by the delete is still reclaimed on time.
enum DeletionPolicy {

    /// How long the user has to undo a delete before the media is reclaimed.
    /// The UI's banner must use this same value, or the banner would offer an
    /// undo that no longer works.
    static let undoWindow: TimeInterval = 5

    /// Every event whose media must survive a sweep right now: the live list,
    /// plus anything still awaiting undo.
    static func mediaOwners(events: [Event], pendingDeletion: Event?) -> [Event] {
        guard let pendingDeletion else { return events }
        return events + [pendingDeletion]
    }
}
