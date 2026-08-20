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

    /// "Tuesday", "Tuesday and Friday", "Tuesday, Thursday and Friday".
    private static func list(_ named: [String]) -> String {
        guard let last = named.last else { return "" }
        guard named.count > 1 else { return last }
        return named.dropLast().joined(separator: ", ") + " and " + last
    }
}
