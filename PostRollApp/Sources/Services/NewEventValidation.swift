import Foundation

/// Whether a new event can be created yet, and why not.
///
/// Its own type so the refusal and the disabled button come from ONE predicate
/// (#402). The sheet used to compute a bare yes/no and grey the button at 40%
/// opacity with nothing said, so a form with two required fields gave no clue
/// which one was missing, and there was not even a tooltip to hover.
enum NewEventValidation {

    /// What is missing, named, or nil when nothing is.
    ///
    /// Returns the sentence rather than a bool so the button and its explanation
    /// cannot disagree: `canCreate` is defined as this being nil, so a state that
    /// blocks creation without a reason is not representable.
    /// The organisation is deliberately NOT asked for (#689).
    ///
    /// A director hiring Dan to shoot a play is not an organisation, and there
    /// is nothing to type. It used to be required, so an event like that could
    /// not be created at all without inventing one, which is worse than leaving
    /// it out: an invented organisation is a fact that goes on to reach a
    /// caption, a folder name and the handle book.
    ///
    /// The parameter is gone rather than kept and ignored. A predicate that
    /// still takes a value it does not read is one every caller believes is
    /// being checked.
    static func refusal(name: String) -> String? {
        guard FieldText.isBlank(name) else { return nil }
        return "Add a name to create this event."
    }

    static func canCreate(name: String) -> Bool {
        refusal(name: name) == nil
    }
}
