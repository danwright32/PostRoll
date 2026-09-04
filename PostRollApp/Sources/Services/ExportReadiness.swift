import Foundation

/// Whether the week is safe to export yet (#89).
///
/// The failure this prevents: Dan applies a change to the Thursday reel, which
/// is a multi-minute ffmpeg rebuild, then presses Approve and Export and picks
/// a folder. The export copies the OLD mp4, because the new one lands in
/// previews after the export finished. The posting week folder silently holds
/// the version without his edits, and he finds out after posting.
///
/// The bottom bar already hid the button during caption regeneration, graphics
/// generation and edit review, but not during per-day rebuilds, which are the
/// longest running of the four.
enum ExportReadiness {

    /// Why this event cannot be exported yet, or nil when it can.
    ///
    /// Returns the reason rather than a bool so the button can be replaced by
    /// something that says what it is waiting for. A control that silently does
    /// nothing, or vanishes with no explanation, reads as broken.
    ///
    /// Two different refusals, in one place because a caller that asked only
    /// one of them would export the other's state. A rebuild in flight resolves
    /// itself and is reported first; a day still drawn for the layout that was
    /// left needs Dan to redraw it, and says so (L11).
    static func blockedReason(for event: Event,
                              preset: PostingPreset,
                              regeneratingDays: Set<DayName>) -> String? {
        blockedReason(regeneratingDays: regeneratingDays,
                      staleDays: PostingLayoutSwitch.staleDays(in: event, preset: preset))
    }

    /// The same two refusals, with the stale days already worked out.
    ///
    /// Both halves are required arguments, so a caller cannot ask half the
    /// question by omission: an empty list is a caller SAYING there are none,
    /// which is a different thing from one that never considered them (L168).
    static func blockedReason(regeneratingDays: Set<DayName>,
                              staleDays: [DayName]) -> String? {
        if let waiting = waitingReason(regeneratingDays: regeneratingDays) { return waiting }
        return staleReason(staleDays)
    }

    static func canExport(for event: Event,
                          preset: PostingPreset,
                          regeneratingDays: Set<DayName>) -> Bool {
        blockedReason(for: event, preset: preset, regeneratingDays: regeneratingDays) == nil
    }

    private static func waitingReason(regeneratingDays: Set<DayName>) -> String? {
        let names = DayName.allCases
            .filter { regeneratingDays.contains($0) }
            .map(\.displayName)
        guard !names.isEmpty else { return nil }
        // Through the one joiner (#933); the verb comes from the same place,
        // so a list of one cannot end up with a plural noun beside it.
        let rebuild = SentenceList.verb(names, singular: "rebuild", plural: "rebuilds")
        return "Waiting for the \(SentenceList.of(names)) \(rebuild)"
    }

    /// A day whose images belong to the layout this event has moved away from
    /// (#1010).
    ///
    /// The switch redraws only the days it changes, so a redraw that failed
    /// leaves the event saying Opening while that day's collage is still
    /// Balanced's four photos. Exporting then ships the wrong picture with
    /// nothing saying so, which is worse than refusing: the folder looks
    /// finished and the mistake is found after posting.
    ///
    /// Phrased as the ACTION, because switching back or redrawing the day are
    /// both real ways out, and a refusal that names no way out is a dead end.
    private static func staleReason(_ stale: [DayName]) -> String? {
        guard !stale.isEmpty else { return nil }
        return "Redraw \(SentenceList.of(stale.map(\.displayName)))"
    }
}
