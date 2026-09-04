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

        guard !result.stale.isEmpty else {
            return "Every day that records its design matches the current design." + tail
        }

        return staleSentence(result) + tail
    }

    /// The stale half of the summary, which since #925 has to separate work
    /// from history.
    ///
    /// The sweep is loudest exactly when it is meant to be most useful: a
    /// design bump marks every day that ever rendered that template, and
    /// regenerating a day whose files have already gone out changes nothing
    /// anyone will see. So the count that LEADS is the actionable one, and the
    /// days already exported are counted after it rather than dropped, because
    /// a day silently removed would make "nothing stale" and "nothing stale
    /// that has not gone out yet" the same answer (L98).
    ///
    /// It says EXPORTED, never posted or published. What the app records is
    /// that the files were written into an export folder; it has no way to know
    /// they reached Instagram, and a sentence may only claim what its record
    /// supports (L11).
    private static func staleSentence(_ result: DesignScanResult) -> String {
        let waiting = result.staleNotExported.count
        let gone = result.staleExported.count

        // Nothing recorded either way. The list has not shrunk, and the reason
        // is that nothing on this machine can say which of these have gone out,
        // which is the state every day folder is in until it is exported again
        // (L223). Said plainly rather than left to read as "none of these has
        // been exported", which is a claim nothing here measured.
        guard gone > 0 else {
            let lead = waiting == 1
                ? "One day was made with an older version of the design."
                : "\(waiting) days were made with an older version of the design."
            return lead + " No day here records having been exported yet, so none "
                 + "could be set aside as finished with. Each starts recording the "
                 + "first time it is exported from here."
        }

        // Every stale day has already been exported. There is nothing here
        // worth acting on, and saying so is a different answer from a library
        // that is current: these assets ARE behind the design, they just are
        // not work on this machine.
        guard waiting > 0 else {
            let they = gone == 1 ? "The one day" : "All \(gone) days"
            return "\(they) made with an older version of the design "
                 + "\(gone == 1 ? "has" : "have") already been exported. "
                 + setAsideReason
        }

        let lead = waiting == 1
            ? "One day was made with an older version of the design."
            : "\(waiting) days were made with an older version of the design."
        let other = gone == 1 ? "day was" : "days were"
        let has = gone == 1 ? "has" : "have"
        return lead + " \(gone) other \(other) made with an older version too and "
             + "\(has) already been exported. " + setAsideReason
    }

    /// Why an exported day is set aside, and what reaching one would take.
    ///
    /// #925 set these apart because rebuilding one does not touch the copies
    /// already written into the export folder, and it was explicit that the
    /// surface must not claim more than the record supports. What PostRoll
    /// records is that a day's files were exported. It has no way of knowing
    /// that anybody saw them, and "gone out" claims exactly that (#1111).
    ///
    /// Not a pedantic distinction. Dan files exports into `1. To Do`,
    /// `2. Not in Metricool` and `3. Done:Waiting to post`, so a day can be
    /// exported and still be waiting, and for that day rebuilding WOULD change
    /// what people eventually see. So the sentence says what is true of every
    /// day in the pile, and names the one step that carries a rebuild out to
    /// them, rather than leaving a set-aside pile with no route out (L111).
    ///
    /// One sentence for both surfaces rather than one written at each, because
    /// two copies of a claim is two things to keep in step and the one that
    /// drifts is the one no test can reach (L41).
    static let setAsideReason =
        "Rebuilding one changes the files here, not the copies already in the "
        + "export folder, so a day still waiting to post would have to be "
        + "exported again."

    /// The line introducing that pile on the sheet.
    ///
    /// Here rather than in the view for the reason this whole type is here:
    /// the wording is the part that goes quietly wrong, and a sentence spelled
    /// inside a view body is one nothing can assert.
    static let exportedSectionBlurb =
        "These are behind the current design too, but their files have already "
        + "been exported. " + setAsideReason

    /// What one row says about a day.
    ///
    /// A row for a day that has gone out names WHEN. "Already exported" with no
    /// date is a claim the reader cannot weigh against a design change they
    /// remember making, and this list exists to be weighed.
    static func rowLabel(_ day: StaleDay) -> String {
        let base = "\(day.dayLabel): \(day.listedTemplates)"
        guard let exportedAt = day.exportedAt else { return base }
        return base + " (exported \(DateFormatter.exportDay.string(from: exportedAt)))"
    }
}
