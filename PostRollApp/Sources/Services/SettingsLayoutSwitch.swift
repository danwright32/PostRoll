import Foundation

/// What changing the DEFAULT posting layout would do to the events that follow
/// it (#1025).
///
/// `Event.effectivePostingPreset` is the event's own override, or the Settings
/// default. So an event with no override silently changed layout the moment
/// that default moved, and nothing computed what changed, warned, or rebuilt
/// anything: those events carried images and captions built for the previous
/// layout with nothing saying so.
///
/// The per event control has confirmed before rebuilding since #1007, and names
/// what it will replace. This is the same decision, `PostingLayoutSwitch.plan`,
/// asked once per event rather than a second rule written beside it (L41), and
/// the same two sentences about what each kind of change costs.
///
/// Events that change NOTHING are counted rather than omitted, and so are the
/// ones with their own override, because a report that names three events out
/// of twelve leaves the reader working out what happened to the other nine
/// (L287).
enum SettingsLayoutSwitch {

    /// One event the switch would touch, and the work it would take.
    struct Affected: Equatable {
        let id: UUID
        let name: String
        let work: PostingLayoutSwitch.Work
    }

    /// Every event, sorted into what the switch does to it.
    struct Impact: Equatable {
        /// Events with no override whose days actually move.
        var affected: [Affected] = []
        /// Events with no override that nothing would change, named so the
        /// count adds up.
        var unaffected: [String] = []
        /// Events carrying their own layout, which a default cannot move.
        var overridden: [String] = []

        var isEmpty: Bool { affected.isEmpty }
    }

    static func impact(from old: PostingPreset, to new: PostingPreset,
                       events: [Event]) -> Impact {
        var impact = Impact()
        for event in events {
            guard event.postingPresetOverride == nil else {
                impact.overridden.append(event.name)
                continue
            }
            let work = PostingLayoutSwitch.work(
                PostingLayoutSwitch.plan(from: old, to: new, in: event))
            if work.redrawDays.isEmpty && work.rebuildDays.isEmpty {
                impact.unaffected.append(event.name)
            } else {
                impact.affected.append(
                    Affected(id: event.id, name: event.name, work: work))
            }
        }
        return impact
    }

    /// What the confirmation says, or nil when there is nothing to confirm.
    ///
    /// Nil rather than an empty string, exactly as the per event control does:
    /// a dialog that appears with nothing to say teaches him to dismiss the one
    /// that matters, and a switch that changes no event takes nothing away.
    ///
    /// The two kinds of change get different sentences because they cost
    /// different things: a redrawn day keeps its caption, a rebuilt one does
    /// not (L11).
    static func confirmation(_ impact: Impact) -> String? {
        guard !impact.isEmpty else { return nil }

        var sentences: [String] = []
        let redrawn = impact.affected.filter { !$0.work.redrawDays.isEmpty }
        let rebuilt = impact.affected.filter { !$0.work.rebuildDays.isEmpty }

        if !redrawn.isEmpty {
            sentences.append("This redraws images on "
                             + SentenceList.of(redrawn.map(\.name)) + ".")
        }
        if !rebuilt.isEmpty {
            let named = SentenceList.of(rebuilt.map(\.name))
            let why = ", because days there become a different kind of post, "
                    + "and any caption you have edited on those days is replaced."
            sentences.append("It rebuilds captions and images on " + named + why)
        }
        sentences.append(tally(impact))
        return sentences.joined(separator: " ")
    }

    /// Where the events that are NOT being touched went.
    private static func tally(_ impact: Impact) -> String {
        var parts: [String] = []
        if !impact.unaffected.isEmpty {
            parts.append("\(count(impact.unaffected.count, "event")) "
                         + "\(impact.unaffected.count == 1 ? "changes" : "change") nothing")
        }
        if !impact.overridden.isEmpty {
            parts.append("\(count(impact.overridden.count, "event")) "
                         + "\(impact.overridden.count == 1 ? "has" : "have") "
                         + "its own layout")
        }
        guard !parts.isEmpty else {
            return "Every event that follows the default is listed above."
        }
        let listed = SentenceList.of(parts)
        return listed.prefix(1).uppercased() + listed.dropFirst() + "."
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
