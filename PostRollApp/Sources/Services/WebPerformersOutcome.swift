import Foundation

/// What OCR does with the performer list fetched from an event's website
/// (#449).
///
/// DCINY events list conductors and group names on the site, which is what Dan
/// wants; the program lists every individual member of every group. The site is
/// the preferred source and the fetch used to sit behind `try?`, so a network
/// failure, a dead script or a changed page produced the same nothing as a page
/// that genuinely lists no performers. Both fell through to the program's list,
/// and the run reported clean.
///
/// Three outcomes, decided here so each can be asserted rather than living
/// inside a private method of a manager that talks to Python.
enum WebPerformersOutcome: Equatable {

    /// The site answered with performers. Use them in place of the program's.
    case use([Performer])

    /// The site was read and lists nobody, or could not be read at all. Keep
    /// the program's list and say why, because a cast list that reads as too
    /// long is otherwise indistinguishable from what the event actually is.
    case keepProgramList(reason: String)

    static func decide(fetched: [Performer]?, failure: String?) -> WebPerformersOutcome {
        // A failure beats a partial answer, the same way it does for any other
        // pass that can die half way: performers read before the error are not
        // the site's list, they are what arrived before it stopped.
        if let failure, !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .keepProgramList(reason: failure)
        }
        guard let fetched, !fetched.isEmpty else {
            return .keepProgramList(reason: "the page listed no performers")
        }
        return .use(fetched)
    }
}
