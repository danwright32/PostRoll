import Foundation

/// A suggested handle another row on this programme already holds (#904).
///
/// The web lookup proposes a handle per performer and each was accepted
/// individually, with nothing checking the proposal against the handles already
/// on the other rows. Accepting one that is taken creates the exact collision
/// `DuplicateHandleMark` exists to report, one step before the warning appears.
///
/// Catching it at the point of the decision is better than warning about the
/// result: the decision has a person in front of it who can still not make it,
/// and the result does not.
enum SuggestionCollision {

    /// The other row already carrying this suggestion's handle, by name, or nil.
    ///
    /// Compared the way `DuplicateHandleMark` compares, so the two agree about
    /// what counts as the same account: bare username, case insensitively,
    /// because Instagram is case insensitive and the field is written both
    /// ways. A SENTINEL is not an account, so two rows recorded as having no
    /// Instagram do not collide (L118).
    ///
    /// The row the suggestion is FOR is never a collision with itself, however
    /// the lookup came to propose what that row already has.
    static func heldBy(_ suggestion: PythonBridge.HandleSuggestion,
                       among performers: [Performer]) -> String? {
        guard let handle = suggestion.handle,
              PythonBridge.isRealHandle(handle) else { return nil }
        let wanted = CaptionBlocks.bareUsername(handle).lowercased()
        let itself = FieldText.normalized(suggestion.name).lowercased()

        for performer in performers {
            guard FieldText.normalized(performer.name).lowercased() != itself else { continue }
            let held = performer.handle.trimmingCharacters(in: .whitespaces)
            guard PythonBridge.isRealHandle(held),
                  CaptionBlocks.bareUsername(held).lowercased() == wanted else { continue }
            let name = FieldText.normalized(performer.name)
            return name.isEmpty ? held : name
        }
        return nil
    }

    /// What the row says instead of offering the button.
    ///
    /// Names the other row, because a refusal that does not say where the
    /// clash is leaves the whole programme to be read by hand (L80). It does
    /// not say which of the two is wrong, because that is not something the app
    /// can know, and picking one would point at the wrong company half the time.
    static func refusal(heldBy other: String) -> String {
        "\(other) already has this handle. Only one of them can, so correct "
        + "whichever row is wrong before accepting this."
    }
}
