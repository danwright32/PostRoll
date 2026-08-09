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

    /// Removes `tags` from every photo in `keys`, leaving every other photo and
    /// every other tag alone (#187).
    ///
    /// Batch tagging could only ever add, so tagging ten photos with the wrong
    /// person took one click and cost ten per-photo popovers to undo, which is
    /// exactly the slowness batch tagging exists to remove. The asymmetry was
    /// invisible until it bit.
    ///
    /// Matching is case-insensitive, because a tag is stored as it was spelled
    /// and "Safa" must remove "safa".
    static func removing(tags: [String],
                         from keys: [String],
                         in existing: [String: [String]]) -> [String: [String]] {
        let doomed = Set(tags
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        guard !doomed.isEmpty, !keys.isEmpty else { return existing }

        var updated = existing
        for key in keys {
            guard let current = updated[key] else { continue }
            let kept = current.filter { !doomed.contains($0.lowercased()) }
            // A photo with no tags left carries no entry at all, the same shape
            // the per-photo editor produces, so an empty array cannot start
            // reading as "tagged with nothing".
            updated[key] = kept.isEmpty ? nil : kept
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

/// The Undo offered after an apply-to-all (#187).
///
/// Holds the tags exactly as they were before the batch, so undoing RESTORES
/// rather than removing what was added. The difference matters: a photo that
/// already carried one of those tags would lose it under a removal, having
/// never been given it by the batch.
struct PhotoTagUndo: Equatable {
    private(set) var snapshot: [String: [String]]?

    var isAvailable: Bool { snapshot != nil }

    /// Remember the pre-batch state, but only if the batch changed something.
    /// Offering Undo after a no-op would imply something happened.
    mutating func record(before: [String: [String]], photosChanged: Int) {
        snapshot = photosChanged == 0 ? nil : before
    }

    /// The state to restore, consuming the undo so it cannot be applied twice.
    mutating func take() -> [String: [String]]? {
        defer { snapshot = nil }
        return snapshot
    }

    /// Called when the sheet moves to another photo. An Undo button under a
    /// different photo is a promise about work the person can no longer see.
    mutating func clear() { snapshot = nil }
}
