import Foundation

/// The rules behind the Thursday editor's removal mode, kept out of the view so
/// they can be asserted without drawing it.
///
/// Photographs are keyed the way `PostingDay.reelRemovedPhotos` and
/// `reelCropOffsets` are: the file URL's `absoluteString`.
enum ReelRemoval {

    /// The removed set after tapping `key`. A marked photo is unmarked; an
    /// unmarked one is marked, unless it is the last photo the reel would
    /// still show, since a reel of nothing is not a render anyone can make.
    ///
    /// `shown` is every photo in the strip on screen, marked or not.
    static func toggling(_ key: String, in removed: Set<String>, shown: [String]) -> Set<String> {
        if removed.contains(key) { return removed.subtracting([key]) }
        let left = shown.filter { !removed.contains($0) }.count
        guard left > 1 else { return removed }
        return removed.union([key])
    }

    /// A photograph on the day that the strip on screen does not show.
    struct LeftOut: Equatable {
        let url: URL
        /// Restored since the strip was rendered: it comes back on the next
        /// render rather than being left out of it.
        let returning: Bool
    }

    /// The row under the strip: every photo the rendered strip left out, in
    /// the day's order. Derived from the strip on screen rather than from the
    /// removed list alone, because a photo marked since the last render is
    /// still in the strip (shown dimmed there) and a restored one is not yet.
    static func leftOut(all: [URL], removed: Set<String>, shown: [String]) -> [LeftOut] {
        let inStrip = Set(shown)
        return all.compactMap { url in
            let key = url.absoluteString
            guard !inStrip.contains(key) else { return nil }
            return LeftOut(url: url, returning: !removed.contains(key))
        }
    }

    /// The line over the strip while marking: how many are marked, how many
    /// remain, and how many is comfortable at this reel's length, so Dan can
    /// see when he has taken out enough without rendering to find out.
    ///
    /// `comfortable` is nil when the length is not known, and then only the
    /// count is given.
    static func banner(marked: Int, shown: Int, comfortable: Int?, reelSeconds: Double?) -> String {
        let left = shown - marked
        let count = marked == 0
            ? "Tap the photos to leave out of the reel."
            : "\(marked) marked, \(left) \(left == 1 ? "photo" : "photos") left."
        guard let comfortable, let reelSeconds else { return count }
        let seconds = Int(reelSeconds.rounded())
        if left <= comfortable {
            return count + " That is comfortable at \(seconds) seconds."
        }
        return count + " About \(comfortable) is comfortable at \(seconds) seconds."
    }
}

/// What the Thursday editor may change about which photographs the reel shows
/// and in what order, handed down as one value.
///
/// One value rather than a parameter each, because `CaptionReviewView`'s body
/// is at the Swift type checker's limit: it replaced the swap closure that was
/// passed before, so the call site carries the same number of arguments.
struct ReelPhotoEdits {
    /// Every photograph on the day, removed ones included, in reel order.
    var allPhotos: [URL]
    /// Keys of the photographs the reel leaves out (`PostingDay.reelRemovedPhotos`).
    var removed: Set<String>
    var swap: (URL, URL) -> Void
    var setRemoved: (Set<String>) -> Void
}
