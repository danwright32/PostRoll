import Foundation

/// What one performer row on the Review screen says under its handle field.
///
/// Two marks can apply to the same row and they say different things. The book
/// mark (#459) is provenance: this value was guessed from a name match rather
/// than read off the programme. The duplicate mark is a contradiction: this
/// value cannot be right for both rows that hold it. Neither replaces the
/// other, so both are shown.
///
/// The order and the weight live here rather than in the view, because they
/// are decisions, and a decision buried in a layout is one nothing asserts
/// (L27).
enum PerformerRowNotes {

    /// One line under the field. `isProblem` is what separates something that
    /// has to be fixed from something that is merely worth knowing, so the row
    /// does not draw two warnings where only one says anything is wrong.
    struct Note: Equatable {
        var text: String
        var isProblem: Bool
        var tooltip: String
    }

    /// What the field holds is not a handle at all (#899).
    ///
    /// The remedy is in the sentence, because the row is where the value was
    /// typed and clearing the field is a real answer rather than a failure:
    /// a performer with no handle is credited by name, which is what should
    /// have happened for the company this was reported on.
    static let notAHandle = "Not an Instagram handle"

    static let notAHandleExplanation =
        "Instagram usernames are letters, digits, periods and underscores, "
        + "with no spaces. This value would be offered to the caption as an "
        + "account to mention, and the mention would go to whoever owns the "
        + "first word of it. Correct it, or clear the field to credit this "
        + "performer by name instead."

    /// The malformed value first, then the clash, then the provenance.
    ///
    /// The order is what has to be acted on soonest. A value that is not a
    /// handle is upstream of the clash: two rows cannot be said to share a
    /// handle when what one of them holds is not one, so the duplicate mark
    /// does not even see it.
    static func lines(duplicate: DuplicateHandleMark.Mark?, isGuessed: Bool,
                      handle: String) -> [Note] {
        var lines: [Note] = []
        let typed = handle.trimmingCharacters(in: .whitespaces)
        // An empty field is not a mistake, it is a performer credited by name.
        // A sentinel is a recorded answer, and it is well shaped anyway.
        if !typed.isEmpty, !CaptionBlocks.isHandleShaped(typed) {
            lines.append(Note(text: notAHandle, isProblem: true,
                              tooltip: notAHandleExplanation))
        }
        if let note = duplicate?.note, !note.isEmpty {
            lines.append(Note(text: note, isProblem: true,
                              tooltip: DuplicateHandleMark.explanation))
        }
        if isGuessed {
            lines.append(Note(text: HandleBookMark.note, isProblem: false,
                              tooltip: HandleBookMark.explanation))
        }
        return lines
    }
}
