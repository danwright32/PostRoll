import Foundation

/// Tagging several carousel photos in one pass (#172). Photos are keyed by
/// their URL `absoluteString`, the same key `PostingDay.photoTags` uses, so
/// nothing here needs a second storage mechanism.
enum PhotoTagBatch {
    /// Adds `tags` to every photo in `keys`, leaving every other photo alone.
    /// Tags a photo already carries are kept as they were spelled: a batch
    /// must only ever add to a photo, never replace what's on it.
    static func applying(tags: [String],
                         to keys: [String],
                         in existing: [String: [String]]) -> [String: [String]] {
        let clean = tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty, !keys.isEmpty else { return existing }

        var updated = existing
        for key in keys {
            var current = updated[key] ?? []
            var seen = Set(current.map { $0.lowercased() })
            for tag in clean where seen.insert(tag.lowercased()).inserted {
                current.append(tag)
            }
            updated[key] = current
        }
        return updated
    }

    /// Copies `tags` onto every photo in the day, for the performer who is in
    /// all of them. Scoped to the day's current photos so a stale entry left
    /// by a removed photo is not revived and tagged.
    static func applyingToAll(tags: [String],
                              dayPhotos: [String],
                              in existing: [String: [String]]) -> [String: [String]] {
        applying(tags: tags, to: dayPhotos, in: existing)
    }

    /// How many of the day's photos actually gained a tag. The confirmation
    /// shown afterwards has to report this rather than the number of photos
    /// asked for: telling Dan it was added to all four when three already had
    /// that person is a success message for something that did not happen.
    static func photosChanged(from before: [String: [String]],
                              to after: [String: [String]],
                              in dayPhotos: [String]) -> Int {
        dayPhotos.filter { (before[$0] ?? []) != (after[$0] ?? []) }.count
    }
}
