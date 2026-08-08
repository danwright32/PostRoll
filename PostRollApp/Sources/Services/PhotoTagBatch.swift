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

    /// The selected photos in the day's posting order, dropping any that have
    /// since been removed. The tagging sheet walks this, so it must read the
    /// way the carousel does rather than the order photos happened to be
    /// clicked.
    static func ordered(_ selected: Set<String>, in ordered: [String]) -> [String] {
        ordered.filter { selected.contains($0) }
    }

    /// What the tagging sheet walks. An empty scope means it was opened from a
    /// photo's own tag button and covers the whole day. A non-empty scope came
    /// from the selection bar and covers only those photos, in posting order,
    /// dropping any since removed. A scope whose photos are all gone stays
    /// empty rather than widening back to the whole day, which would silently
    /// put every photo in reach of an apply-to-all.
    static func scope(_ scope: [String], in dayPhotos: [String]) -> [String] {
        guard !scope.isEmpty else { return dayPhotos }
        return ordered(Set(scope), in: dayPhotos)
    }
}

/// Which photos are currently picked out for a batch action, plus the anchor
/// a shift-click extends from.
struct PhotoSelection: Equatable {
    private(set) var keys: Set<String> = []
    private(set) var anchor: String?

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    /// Plain click on the selection control: add or remove one photo. Either
    /// way that photo becomes the anchor for the next shift-click.
    mutating func toggle(_ key: String) {
        if keys.contains(key) {
            keys.remove(key)
        } else {
            keys.insert(key)
        }
        anchor = key
    }

    /// Shift-click: select everything between the anchor and `key` inclusive,
    /// in whichever direction they sit. With no live anchor (first click, or
    /// the anchored photo has since been removed) this is just a plain pick.
    mutating func extend(to key: String, in ordered: [String]) {
        guard let target = ordered.firstIndex(of: key) else { return }
        guard let anchor, let start = ordered.firstIndex(of: anchor) else {
            keys.insert(key)
            self.anchor = key
            return
        }
        for i in min(start, target)...max(start, target) {
            keys.insert(ordered[i])
        }
    }

    mutating func clear() {
        keys.removeAll()
        anchor = nil
    }

    /// Drops photos that are no longer in the day. A key left behind after a
    /// photo was removed would silently take a later batch tag with it.
    mutating func prune(to ordered: [String]) {
        let live = Set(ordered)
        keys.formIntersection(live)
        if let anchor, !live.contains(anchor) { self.anchor = nil }
    }
}
