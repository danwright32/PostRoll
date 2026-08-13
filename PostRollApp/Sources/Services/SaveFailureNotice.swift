import Foundation

/// The words for a save that failed mid-session (#446).
///
/// `EventStore.save` has always returned an outcome and every caller threw it
/// away, so a save that began failing during an editing session reached NSLog and
/// nothing else, then failed again silently on every subsequent edit. events.json
/// is, by the store's own comment, the single copy of every caption, blog, OCR
/// result and crop edit: an evening of work could be lost by quitting, with the
/// screen showing every word of it the whole time. Load failures were surfaced
/// from the start; saves were not (L12).
///
/// Its own type rather than a string built at the call site, so the wording is
/// tested once and cannot drift between the paths that reach it.
enum SaveFailureNotice {

    /// What the retry control says. Named here so the message and the button
    /// cannot end up describing different actions.
    static let retryLabel = "Try saving again"

    /// Through `Sentence` because the reason comes from the file system and may
    /// end in a stop, a question mark, an ellipsis, or nothing at all.
    static func message(reason: String) -> String {
        "Your latest edits have not been saved: \(Sentence.closed(reason)) "
        + "They are still on screen but not on disk, so quitting now would lose "
        + "them. Fix the problem and press \(retryLabel), or copy anything you "
        + "cannot lose somewhere else first."
    }
}
