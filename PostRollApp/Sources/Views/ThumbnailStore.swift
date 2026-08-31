import AppKit
import CoreGraphics
import Foundation

/// One decoded image per file and size, decoded once and kept (#966).
///
/// Every photo in this app was read with `NSImage(data:)`, which keeps the
/// compressed bytes and decodes them lazily at draw time on the main thread.
/// macOS discards SwiftUI's cached image surfaces whenever the app leaves the
/// foreground, so coming back to PostRoll decoded every visible photo again
/// from scratch before the window could draw. That is the freeze Dan reported
/// on 2026-08-29, and it is why launching the app and switching back to it feel
/// identical: both are a cold texture cache.
///
/// `ImageLoad.decode` fixes the decode. This fixes the AGAIN. Without a cache
/// the same photo is re-derived from the original on every cold draw, which is
/// the second half of the sentence #966 asks for.
///
/// An actor rather than a lock, because the store is read from every `.task`
/// on the screen at once. The decode itself is deliberately NOT inside the
/// actor's isolation: it runs in a detached task, so eighty thumbnails decode
/// alongside each other rather than one behind another. The cost of that is
/// that two callers missing on the same key at the same moment both decode.
/// That is wasted work and nothing else: the decode is a pure function of the
/// file, and whichever finishes last simply overwrites an identical entry.
actor ThumbnailStore {
    static let shared = ThumbnailStore()

    /// What a cached entry holds. A class because `NSCache` stores objects.
    private final class Entry {
        let decoded: ImageLoad.DecodedImage
        init(_ decoded: ImageLoad.DecodedImage) { self.decoded = decoded }
    }

    /// Bounded in BYTES rather than in entries, because entries are not one
    /// size: an 80pt grid square costs about 100KB and a lightbox costs tens of
    /// megabytes, so a count limit would either evict thumbnails constantly or
    /// hold several full frames. The number this replaces was 1.3GB resident on
    /// the running app, roughly eighty full size photos.
    ///
    /// `NSCache` rather than a dictionary with an eviction rule written here:
    /// it already drops entries under real memory pressure, which a hand
    /// written limit cannot notice.
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    /// The decoded image for `url` at `maxPixel`, from the cache or freshly
    /// decoded, or nil when the file is not there and not readable.
    func image(for url: URL, maxPixel: Int) async -> ImageLoad.DecodedImage? {
        guard let key = Self.key(url, maxPixel: maxPixel) else { return nil }
        if let hit = cache.object(forKey: key) { return hit.decoded }
        let decoded = await Task.detached {
            ImageLoad.decode(url, maxPixel: maxPixel)
        }.value
        guard let decoded else { return nil }
        cache.setObject(Entry(decoded), forKey: key, cost: decoded.byteCost)
        return decoded
    }

    /// What the cache is keyed on.
    ///
    /// The path is not enough. Photos in this app are EDITED in place: a crop
    /// or a resize rewrites the file and leaves the path alone, so a key that
    /// is only the path serves the picture from before the edit forever, and
    /// the person sees their change not happen (L40). The modification date and
    /// the size both move when the bytes move, so both are in the key.
    ///
    /// Nil when the file cannot be stat'ed at all, which is the missing case
    /// and is answered as a miss rather than as an entry. A cache that cannot
    /// tell whether its subject changed must not answer (L215).
    /// Through `FileManager` rather than `URL.resourceValues`, which CACHES
    /// what it read on the URL instance. A SwiftUI view holds one `URL` for its
    /// whole life and hands the same instance to every read, so the cached
    /// answer is the one from before the edit and the key never moves. Caught
    /// by the test above rather than by reading: the code is correct in shape
    /// and the staleness lives entirely inside Foundation.
    static func key(_ url: URL, maxPixel: Int) -> NSString? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let bytes = attributes[.size] as? Int
        else { return nil }
        return "\(url.path)|\(modified.timeIntervalSince1970)|\(bytes)|\(maxPixel)" as NSString
    }

    /// Empty the store. For tests, which must be able to reach the cold path
    /// deliberately: a suite that can only ever measure a warm cache proves
    /// nothing about the draw this exists to fix.
    func clear() { cache.removeAllObjects() }
}
