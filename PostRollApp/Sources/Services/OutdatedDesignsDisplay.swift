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

    /// The line at the top, which has to tell four states apart.
    ///
    /// "Nothing has been rendered yet", "days exist but none of them record
    /// which design made them" and "everything that could be checked is
    /// current" are different answers, and a surface that gives the reassuring
    /// one for all three is telling the person their assets are fine when it has
    /// not been able to look at any (LESSONS.md L98, L10).
    ///
    /// The middle state is not hypothetical: #311 measured every day folder on
    /// Dan's Mac and none carries a record, so this surface reports an empty
    /// list and will keep doing so until a day is rendered again. Backfilling a
    /// version to make the list work was rejected, because the file dates
    /// contradict the claim it would have written. Owning what could not be
    /// checked is what is left, and it is the honest half of that decision.
    static func summary(_ result: DesignScanResult, hasPreviewRoot: Bool) -> String {
        guard hasPreviewRoot, result.daysWithAssets > 0 else {
            return "There are no rendered assets on this Mac yet, so there is "
                 + "nothing to compare against the current design."
        }

        let unchecked = max(0, result.daysWithAssets - result.daysWithARecord)

        // Nothing on the machine could be compared at all. Said on its own,
        // because appending it to a reassuring sentence would bury the fact
        // that the reassurance covers no days whatsoever.
        if result.daysWithARecord == 0 {
            let days = unchecked == 1 ? "day" : "days"
            let they = unchecked == 1 ? "it was" : "they were"
            return "\(unchecked) rendered \(days) here do not record which design "
                 + "made them, so none could be checked. Each starts reporting the "
                 + "first time it is regenerated, which is also the moment "
                 + "\(they) rebuilt with the current design."
        }

        let tail = unchecked == 0 ? "" :
            " \(unchecked) other \(unchecked == 1 ? "day does" : "days do") not "
            + "record which design made \(unchecked == 1 ? "it" : "them"), so "
            + "\(unchecked == 1 ? "it" : "they") could not be checked."

        switch result.stale.count {
        case 0:
            return "Every day that records its design matches the current design."
                 + tail
        case 1:
            return "One day was made with an older version of the design." + tail
        default:
            return "\(result.stale.count) days were made with an older version "
                 + "of the design." + tail
        }
    }

    /// What one row says about a day.
    static func rowLabel(_ day: StaleDay) -> String {
        "\(day.dayLabel): \(day.listedTemplates)"
    }
}
