import Foundation

/// An owner of work that outlives the screen that started it, and can say so.
///
/// `AppOwners` holds nine of these (#718). Before #862 only three of them could
/// be asked whether they were busy, and the one place that asked, the refusal to
/// start an update while work is in flight (#686), named those three by hand.
/// The other six were invisible to it: a performer lookup, an Insights
/// analysis, a caption rerun, an OCR reflow, a notes search and a collage render
/// could all be running while the app said nothing was.
///
/// A list of owners maintained beside the list of owners is a list the two can
/// disagree about, and that is the exact defect `AppOwners` was created to end
/// (L41, L96). So the question is asked of the container itself and every member
/// answers it.
@MainActor
protocol BackgroundWork {
    /// Whether anything this owner started is still running.
    var hasWorkInFlight: Bool { get }

    /// What to call it inside a sentence, as a clause: "a week is still
    /// generating". Written to sit after "cannot update while" and after "if you
    /// quit now", so it has to read as a statement rather than a noun.
    var workPhrase: String { get }
}

/// Everything running right now, across a container of owners.
///
/// Reflection rather than a written out list of the nine properties, because a
/// written out list is the thing being removed: adding an owner to `AppOwners`
/// would otherwise have to be remembered here too, and the entries anybody
/// remembers are the ones already safe.
///
/// `QuitWithWorkInFlightTests` holds both ends of this: that every member of
/// `AppOwners` is reachable through it, and, on a stub container built to be
/// busy, that a running owner is actually found. The second is not decoration.
/// An idle app reports nothing in flight whether this works or is a stub
/// returning an empty array, and the broken version passes every test that only
/// ever looks at an idle app (L98).
@MainActor
enum BackgroundWorkScan {
    static func inFlight(of container: Any) -> [String] {
        Mirror(reflecting: container).children.compactMap { child in
            guard let owner = child.value as? BackgroundWork, owner.hasWorkInFlight else {
                return nil
            }
            return owner.workPhrase
        }
    }
}

/// What quitting should do right now.
///
/// A value with no AppKit in it, so the decision can be read and tested without
/// a running application, in the same way `ModalQueue` keeps the window's modal
/// rule testable without a window.
enum QuitDecision: Equatable {
    /// Nothing is running. Quitting takes nothing away.
    case quitNow
    /// Something is running, and this is what to put in front of Dan.
    case ask(String)
}

/// Whether quitting PostRoll right now would destroy work (#862).
///
/// It ASKS rather than refusing, and Quit Anyway is always available. That is
/// Dan's decision, taken on 2026-08-23, and the reason is the logout: a hard
/// refusal there leaves a machine that will not log out for a reason buried in
/// an app he is not looking at, and the system may kill PostRoll anyway, so the
/// refusal would have cost him the log out without saving the work.
enum QuitGuard {

    static func decision(workInFlight: [String]) -> QuitDecision {
        guard !workInFlight.isEmpty else { return .quitNow }
        return .ask(question(workInFlight))
    }

    /// The words on the dialog.
    ///
    /// Says what is running and what quitting costs, rather than asking "are you
    /// sure": a confirmation that carries no information reads the same whether
    /// it is about a two second lookup or a twenty minute generation, and gets
    /// clicked through on reflex (L180).
    private static func question(_ work: [String]) -> String {
        "PostRoll is still working: \(WorkPhrases.list(work)). Quitting now "
            + "stops it, and anything not yet saved is lost."
    }
}

/// Joining the clauses, in one place.
///
/// Both the quit question and the refusal to start an update are composed from
/// the same phrases and joined the same way, because two sentences built from
/// two lists drift, and they drift into disagreeing about whether it is safe to
/// quit, which is the single thing both exist to say (L144).
enum WorkPhrases {
    /// "a and b", "a, b and c". Written out because these sentences read badly
    /// with a bare comma.
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
