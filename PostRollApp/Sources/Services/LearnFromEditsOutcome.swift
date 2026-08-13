import Foundation

/// What the caption screen does when the learn-from-edits pass comes back
/// (#526).
///
/// That pass is a paid Claude call that reads Dan's hand edits and proposes a
/// line for his brand voice file. It ran behind `try?`, so a call that FAILED
/// returned the same nil as a call that succeeded with nothing worth saying.
/// Both took the branch that advances the week, and Dan was told nothing, so
/// the edits he made went unreviewed and looked exactly like edits the model
/// had nothing to add to.
///
/// Three outcomes, kept apart on purpose (L11), and decided here rather than in
/// the view so each one can be asserted.
enum LearnFromEditsOutcome: Equatable {

    /// The pass has something to propose. Show it for Dan to edit or skip.
    case offerSuggestion(String)

    /// The pass ran and had nothing to add. Carry on to the export.
    case advance

    /// The pass did not run to completion. Say so, rather than moving on as
    /// though it had answered.
    case reportFailure(String)

    static func decide(suggestion: String?, failure: String?) -> LearnFromEditsOutcome {
        // A failure beats whatever came back before it. A partial answer put in
        // front of Dan as a suggestion would be the failure hiding behind the
        // thing it interrupted.
        if let failure, !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .reportFailure(failureNotice(failure))
        }
        let text = suggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? .advance : .offerSuggestion(suggestion ?? "")
    }

    /// Names the cause, and then what is and is not at stake.
    ///
    /// The captions are already written to the store by the time this runs, so
    /// the thing at risk is the learning, not the week. Saying that is what
    /// stops the notice reading as "your edits are gone".
    static func failureNotice(_ reason: String) -> String {
        "Your edits could not be reviewed, so nothing was learned from them: "
        + Sentence.closed(reason)
        + " Your captions are saved and the week can still be exported."
    }
}
