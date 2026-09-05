import Foundation

/// What one posting layout switch says when it finishes (#1046).
///
/// A day rebuilt from the review screen announces itself as it lands. A layout
/// switch that only needs the images redrawn announced nothing, deliberately:
/// per day it would report three finished rebuilds for one thing Dan did. That
/// left the quiet case silent for a run of several minutes, so a finished
/// switch and one still going looked identical unless he watched the screen,
/// which is the shape #95 exists to prevent.
///
/// One notice for the batch, then, sent when the last claimed day lands, and it
/// has to be able to say that SOME days landed: announcing a partial switch as
/// finished is a success claim over work that did not happen (L12).
enum LayoutSwitchNotice {

    /// The notice, or nil when the switch touched no day at all.
    struct Notice: Equatable {
        /// The middle of the sentence the notification centre shows, the same
        /// slot a single day's rebuild fills with "Wednesday".
        let what: String
        /// Whether anything failed, so the caller can send this through the
        /// failure path rather than the ready one. Two states nobody can tell
        /// apart is what a partial switch would otherwise be (L11).
        let isFailure: Bool
    }

    static func of(landed: [DayName], failed: [DayName]) -> Notice? {
        guard !landed.isEmpty || !failed.isEmpty else { return nil }
        let done = named(landed)
        let lost = named(failed)

        if failed.isEmpty {
            return Notice(what: "\(done) redrawn", isFailure: false)
        }
        if landed.isEmpty {
            return Notice(what: "\(lost) could not be redrawn", isFailure: true)
        }
        return Notice(what: "\(done) redrawn, and \(lost) could not be",
                      isFailure: true)
    }

    /// The days in the WEEK's order rather than the order the renderer
    /// happened to finish them in, so two switches over the same days read the
    /// same way (L343).
    private static func named(_ days: [DayName]) -> String {
        let ordered = DayName.allCases.filter(days.contains)
        return SentenceList.of(ordered.map(\.displayName))
    }
}
