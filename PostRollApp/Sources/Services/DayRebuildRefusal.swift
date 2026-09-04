import Foundation

/// What the caption review screen says when it will not start a rebuild (#728).
///
/// Kept out of the view so the wording can be pinned by a test, the way
/// `ImportFailureText` and `ProjectRootText` are.
///
/// It says nothing was changed, because that is the part Dan cannot see for
/// himself: the action's own write is deliberately not made. Every one of these
/// actions persists something before the render (new photos, a fresh seed, a
/// cleared audio track, a clip override), and making that write and then
/// refusing to render would leave the event describing a reel that does not
/// exist. Starting anyway is two subprocesses writing one MP4.
///
/// It names the days rather than saying "the day is busy", so the sentence tells
/// him which control to wait on (L80), and it names them in the week's own order
/// so two refusals about the same days read identically.
enum DayRebuildRefusal {

    /// Nil for no days: a refusal about nothing would render an empty red row,
    /// claiming a problem it cannot describe (L11).
    static func message(for days: [DayName]) -> String? {
        let named = DayName.allCases.filter { days.contains($0) }.map(\.displayName)
        guard !named.isEmpty else { return nil }
        let subject = list(named)
        let plural = named.count > 1
        return "\(subject) \(plural ? "are" : "is") still rebuilding, so nothing was "
             + "changed. Wait for \(plural ? "them" : "it") to finish, then try again."
    }

    /// What the screen's two refusal slots hold once a rebuild HAS been granted.
    ///
    /// The rule, in one place because it was wrong the first time and the code
    /// that got it wrong was three lines inside a two thousand line screen
    /// (#731).
    ///
    /// A rebuild refused because that day was already rebuilding stops being
    /// true the moment the day is free, so a grant takes it away. A refusal
    /// about something else does not: a file that would not copy, or a photo set
    /// too small to lay out, is not answered by a rebuild starting. Clearing
    /// both on a grant destroyed exactly the half of a partly failed batch that
    /// nothing else reports, because `importFridayClips` says which picks failed
    /// to copy and then rebuilds with the ones that landed, in that order (L47).
    static func afterRebuildGranted(action: String?, rebuild: String?)
    -> (action: String?, rebuild: String?) {
        (action, nil)
    }

    /// "Tuesday", "Tuesday and Friday", "Tuesday, Thursday, and Friday",
    /// through the one joiner (#933).
    private static func list(_ named: [String]) -> String { SentenceList.of(named) }
}
