import Foundation

/// Which controls a photo thumbnail offers. Cropping and per-photo tagging
/// are separate features that happen to share a thumbnail, and they cover
/// different days: crop is Wednesday and Thursday, tagging is every day laid
/// out as a carousel (Wednesday always, plus Sunday and Monday under the
/// balanced preset). Expressing one through the other hid tagging on Sunday
/// and Monday entirely, so each control answers only to its own feature.
enum PhotoThumbControls {
    static func showsCrop(cropEnabled: Bool, taggingEnabled: Bool) -> Bool {
        cropEnabled
    }

    static func showsTagging(taggingEnabled: Bool, cropEnabled: Bool) -> Bool {
        taggingEnabled
    }

    /// Whether the thumbnail carrying the controls is needed at all. The plain
    /// thumbnail is only right when a day has neither feature.
    static func usesDetailedThumb(cropEnabled: Bool, taggingEnabled: Bool) -> Bool {
        cropEnabled || taggingEnabled
    }
}
