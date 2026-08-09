import Foundation

/// Which controls a photo thumbnail offers. Cropping and per-photo tagging
/// are separate features that happen to share a thumbnail, and they cover
/// different days: crop is Wednesday and Thursday, tagging is every day laid
/// out as a carousel (Wednesday always, plus Sunday and Monday under the
/// balanced preset). Expressing one through the other hid tagging on Sunday
/// and Monday entirely, so each control answers only to its own feature.
enum PhotoThumbControls {

    /// Where a photo thumbnail is being shown.
    enum Surface {
        /// The upload page, before anything has been generated.
        case upload
        /// The review page, over the rendered collage.
        case review
    }

    /// Whether this surface offers a crop control (#189).
    ///
    /// One editor per setting, on the surface where its effect is visible. The
    /// upload page used to offer a crop popover against an 80pt thumbnail,
    /// before anything was generated and with no view of the collage cell the
    /// crop applies to, while writing the same `cropOffsets` storage the review
    /// page edits. Two editors for one value, and that one the worse.
    ///
    /// Named rather than left implicit in deleted code, so re-adding the button
    /// means arguing with this rule instead of quietly reintroducing it.
    static func offersCropControl(on surface: Surface) -> Bool {
        switch surface {
        case .upload: return false
        case .review: return true
        }
    }

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
