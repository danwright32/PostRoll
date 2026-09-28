import Foundation

/// What saving Edit Details changed, and what it leaves out of date (#1448).
///
/// Computed from the event before and after the save, never from the form, so
/// a save that typed the same values back offers nothing to refresh.
struct EventDetailsSave: Equatable {
    /// Whether any of the four details is different.
    let changed: Bool

    /// The days whose graphics print the old details, in the week's order.
    ///
    /// Every day with graphics, because nearly every template prints the
    /// organisation or the venue: the story plates, the collage, the reels and
    /// the before and after. Redrawn from the saved layout and crops, so only
    /// the text moves.
    let refreshDays: [DayName]

    /// Whether an export already on disk shows old text on its graphics, which
    /// only exporting again replaces.
    let exportIsStale: Bool

    init(before: Event, after: Event) {
        // The hall or room reaches only the blog and captions, never a graphic.
        let printed = before.name != after.name || before.org != after.org
            || before.venue != after.venue
        changed = printed || before.venueContext != after.venueContext
        let rendered = Set(after.previewMediaPaths.filter { !$0.value.isEmpty }.keys)
        refreshDays = printed ? DayName.allCases.filter { rendered.contains($0.rawValue) } : []
        exportIsStale = printed && after.isExported
    }
}
