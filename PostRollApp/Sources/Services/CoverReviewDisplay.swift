import Foundation

/// Pure decisions CaptionSection uses for the Cover card (#141), extracted
/// so they're unit-testable without SwiftUI/AppKit. Mirrors
/// FridayReviewDisplay.showsDualSlot's file-existence guard.
enum CoverReviewDisplay {
    /// Whether the Cover card should render its thumbnail: a rendered
    /// cover.png path must exist AND still be present on disk. A stale
    /// path surviving after the file was reclaimed/deleted must not show a
    /// broken image.
    static func showsCover(coverPath: String?, fileExists: (String) -> Bool) -> Bool {
        guard let coverPath else { return false }
        return fileExists(coverPath)
    }

    /// The rationale text to show under the thumbnail: nil once a manual
    /// override is in effect (there's no AI rationale for the user's own
    /// pick, even if a stale one is still persisted), otherwise the AI's
    /// one-line rationale when it has one.
    static func rationale(coverOverride: String?, coverPick: CoverPick?) -> String? {
        guard coverOverride == nil else { return nil }
        guard let pick = coverPick, !pick.rationale.isEmpty else { return nil }
        return pick.rationale
    }
}
