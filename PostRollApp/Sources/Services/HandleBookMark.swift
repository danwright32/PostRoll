import Foundation

/// Marking a handle the handle book guessed, rather than one read off this
/// programme (#459).
///
/// The book is keyed on a normalised NAME and is global across every org and
/// every event, so a second performer who happens to share a name inherits the
/// first one's Instagram. That value landed in the field indistinguishable
/// from one the programme actually printed, which is the silent substitution
/// L75 is about: when identifying who something refers to is a guess, it must
/// not be presented as a fact.
///
/// The web lookup in the same screen already does this properly, with a
/// confidence dot, a verify link and an explicit Accept. This is the same
/// distinction for the cheaper source.
enum HandleBookMark {

    /// Whether a performer's handle is still the one the book supplied.
    ///
    /// Derived by comparison rather than held as a flag, so the mark clears the
    /// moment Dan edits the field: once he has typed it himself it is his
    /// answer, not a guess, and a marker still saying otherwise would be
    /// telling him something untrue (L14).
    static func isFromTheBook(supplied: String?, current: String) -> Bool {
        guard let supplied, !supplied.isEmpty else { return false }
        return supplied == current
    }

    /// What the mark says. Names the whole of the risk in one line, because the
    /// risk is specific: it is a name match, not a person match.
    static let note = "From your handle book, matched on name alone"

    /// The longer version, for the tooltip.
    static let explanation =
        "This handle was filled in from a performer with the same name in an "
        + "earlier event, not read from this program. Check it belongs to this "
        + "person before continuing."
}
