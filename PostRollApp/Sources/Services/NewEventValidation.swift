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
    static func refusal(name: String, org: String) -> String? {
        var missing: [String] = []
        if FieldText.isBlank(name) {
            missing.append("a name")
        }
        if FieldText.isBlank(org) {
            missing.append("an organisation")
        }
        guard !missing.isEmpty else { return nil }
        return "Add \(missing.joined(separator: " and ")) to create this event."
    }

    static func canCreate(name: String, org: String) -> Bool {
        refusal(name: name, org: org) == nil
    }
}
