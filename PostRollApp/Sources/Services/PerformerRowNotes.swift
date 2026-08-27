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

    /// The clash first. It is the line that has to be acted on, while knowing
    /// where a value came from does not make it correct.
    static func lines(duplicate: DuplicateHandleMark.Mark?, isGuessed: Bool) -> [Note] {
        var lines: [Note] = []
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
