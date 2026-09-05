import Foundation

/// How much of one day's per-photo tagging is left to do (#1361).
///
/// Dan chose per-photo tagging over plumbing the photographs into the blog
/// revision path (#980), and that decision rests on the tagging being
/// practical. Measured on 2026-09-04, 206 of 255 blog photos carried no tag,
/// and the only thing on screen saying so was an outlined tag glyph rather than
/// a filled one on each 80pt thumbnail. Finding out what was left meant opening
/// every photo, and there was no way to tell when the job was done, which is
/// the difference between a task and a chore.
///
/// It counts PHOTOS, not tag entries. An entry for a photograph that has since
/// been removed from the day says nothing about the ones that are still there,
/// and counting entries would report a day as finished because a deleted
/// photograph was once tagged.
enum PhotoTagProgress {

    /// How many of `photos` carry no usable tag.
    ///
    /// An entry holding an empty list, or only blank strings, is not a tagged
    /// photograph. The thumbnail writes nil rather than an empty array when the
    /// last tag is removed, but an event stored before that does carry the
    /// empty list, and reading it as done would report the work finished while
    /// the photograph names nobody (L11).
    static func untagged(photos: [URL], tags: [String: [String]]) -> Int {
        photos.filter { photo in
            let named = (tags[photo.absoluteString] ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return named.isEmpty
        }.count
    }

    /// What the day's header says about it, or nil when there is nothing to
    /// say.
    ///
    /// The finished state is its own sentence rather than silence. A day with
    /// nothing left and a day nobody has started both said nothing before, and
    /// telling those apart is the whole point of showing a count: the surface
    /// that reports progress would otherwise go quietest exactly when the work
    /// is complete (L11, L152).
    ///
    /// Nil only for a day with no photographs at all, where there is no tagging
    /// to report and "all tagged" would claim work that never happened (L98).
    static func note(photos: [URL], tags: [String: [String]]) -> String? {
        guard !photos.isEmpty else { return nil }
        let left = untagged(photos: photos, tags: tags)
        return left == 0 ? "all tagged" : "\(left) still to tag"
    }
}
