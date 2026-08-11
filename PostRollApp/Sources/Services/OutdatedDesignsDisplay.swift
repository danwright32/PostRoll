import Foundation

/// One event's worth of days whose cached assets are behind (#293).
struct OutdatedDesignsGroup: Identifiable, Hashable {
    /// The event this preview folder belongs to, or nil when no event on record
    /// matches it. Nil is what makes the row unopenable, so it is carried rather
    /// than resolved again at the point of the button.
    let eventID: Event.ID?
    /// What to call it: the event's own name, or the folder name when there is
    /// no event to name.
    let title: String
    let days: [StaleDay]

    var id: String { days.first?.eventSlug ?? title }
}

/// What the outdated designs surface shows (#293).
///
/// Kept out of the view so the wording and the matching can be asserted. The
/// matching is the part that goes quietly wrong: a preview folder is named by
/// Python's slug, and the only thing tying it back to a record is that same
/// slug computed on this side.
enum OutdatedDesignsDisplay {

    /// Stale days grouped by the event they belong to, in scan order.
    ///
    /// A folder that matches no event is still listed. Its assets exist, and
    /// silently dropping it would make the surface claim a clean machine while
    /// old files sat on disk. It cannot be opened, and the row says so.
    static func groups(_ stale: [StaleDay], events: [Event]) -> [OutdatedDesignsGroup] {
        var order: [String] = []
        var byslug: [String: [StaleDay]] = [:]
        for day in stale {
            if byslug[day.eventSlug] == nil { order.append(day.eventSlug) }
            byslug[day.eventSlug, default: []].append(day)
        }
        return order.map { slug in
            let match = events.first { ArchiveCleanup.slug(event: $0) == slug }
            return OutdatedDesignsGroup(
                eventID: match?.id,
                title: match?.name ?? slug,
                days: byslug[slug] ?? [])
        }
    }

    /// The line at the top, which has to tell three states apart.
    ///
    /// "Nothing has been rendered yet" and "everything is current" are different
    /// answers, and a surface that gives the reassuring one for both is telling
    /// the person their assets are fine when it has not looked at any
    /// (LESSONS.md L98, L10).
    static func summary(dayCount: Int, hasPreviewRoot: Bool) -> String {
        guard hasPreviewRoot else {
            return "There are no rendered assets on this Mac yet, so there is "
                 + "nothing to compare against the current design."
        }
        switch dayCount {
        case 0:
            return "Every rendered day matches the current design."
        case 1:
            return "One day was made with an older version of the design."
        default:
            return "\(dayCount) days were made with an older version of the design."
        }
    }

    /// What one row says about a day.
    static func rowLabel(_ day: StaleDay) -> String {
        "\(day.dayLabel): \(day.listedTemplates)"
    }
}
