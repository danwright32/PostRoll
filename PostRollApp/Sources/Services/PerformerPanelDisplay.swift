import Foundation

/// Pure decisions PerformerAssignmentSection uses (#171), extracted so
/// they're unit-testable without SwiftUI. On a carousel day people are
/// tagged photo by photo, and those tags now credit the caption directly,
/// so the day-level panel becomes a fallback for anyone who can't be
/// pinned to a single frame (a conductor never cleanly in shot, an
/// ensemble credited as a whole).
enum PerformerPanelDisplay {
    /// Whether the panel opens on first render. It steps back on carousel
    /// days, but only when there is nothing in it: picks already made must
    /// never be tucked behind a collapsed header where they'd read as lost.
    static func startsExpanded(isCarouselDay: Bool, hasContent: Bool) -> Bool {
        guard isCarouselDay else { return true }
        return hasContent
    }

    static func title(isCarouselDay: Bool) -> String {
        isCarouselDay ? "PEOPLE ACROSS THE WHOLE POST" : "ASSIGN PERFORMERS"
    }

    /// One line explaining when to reach for this panel rather than the tag
    /// button on a photo. Only carousel days have that choice to explain.
    static func hint(isCarouselDay: Bool) -> String? {
        guard isCarouselDay else { return nil }
        return "Tag people on the photos above. Use this only for someone who belongs to the post but isn't in any one photo."
    }
}
