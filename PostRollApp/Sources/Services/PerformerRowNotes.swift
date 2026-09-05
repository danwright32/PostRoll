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

    /// The field holds a value the shared check refuses while being shaped
    /// like a handle: one of the sentinels the pipeline writes when a search
    /// found nobody (#1371).
    ///
    /// Not a problem. It is a RECORDED ANSWER, which is why the book keeps it:
    /// a name searched for once is not searched for again. What was wrong was
    /// saying nothing, so a value that no surface will ever treat as an
    /// account read exactly like one that will, and the performer was silently
    /// untaggable, uncreditable and not invitable (L11).
    static let searchedAndNotFound = "Searched for, and no account found"

    static let searchedAndNotFoundExplanation =
        "This is the answer a handle search wrote down when it found nobody, "
        + "kept so the same name is not searched for again. No caption, tag or "
        + "invite will use it. Type the account if you know it, or clear the "
        + "field to credit this performer by name."

    /// The address the research step fetched and confirmed this handle against
    /// (#987, #1373).
    ///
    /// A quiet mark on the ones that HAVE one rather than a warning on the
    /// ones that do not: most handles are Dan's own answers, typed or filled
    /// from the book, and marking those unverified would accuse the accounts
    /// most likely to be right.
    static let checkedAgainstTheProfile = "Checked against the profile"

    static let checkedExplanation =
        "Somebody opened this account's profile and kept the address, so this "
        + "handle is known to be a real account rather than a convention. A "
        + "handle with no such mark is not wrong, only unchecked."

    /// The malformed value first, then the clash, then the provenance.
    ///
    /// The order is what has to be acted on soonest. A value that is not a
    /// handle is upstream of the clash: two rows cannot be said to share a
    /// handle when what one of them holds is not one, so the duplicate mark
    /// does not even see it.
    static func lines(duplicate: DuplicateHandleMark.Mark?, isGuessed: Bool,
                      handle: String, checkedProfile: String? = nil) -> [Note] {
        var lines: [Note] = []
        let typed = handle.trimmingCharacters(in: .whitespaces)
        // An empty field is not a mistake, it is a performer credited by name.
        if !typed.isEmpty, !CaptionBlocks.isHandleShaped(typed) {
            lines.append(Note(text: notAHandle, isProblem: true,
                              tooltip: notAHandleExplanation))
        } else if !typed.isEmpty, !PythonBridge.isRealHandle(typed) {
            // Shaped like a handle and still refused by the shared check, which
            // is the sentinel case and nothing else (#1371).
            lines.append(Note(text: searchedAndNotFound, isProblem: false,
                              tooltip: searchedAndNotFoundExplanation))
        }
        if let note = duplicate?.note, !note.isEmpty {
            lines.append(Note(text: note, isProblem: true,
                              tooltip: DuplicateHandleMark.explanation))
        }
        if isGuessed {
            lines.append(Note(text: HandleBookMark.note, isProblem: false,
                              tooltip: HandleBookMark.explanation))
        }
        // Last, and only on a value that is really an account: a checked
        // address on a sentinel would be two marks contradicting each other,
        // and the check is what decides which of them is true.
        if let checkedProfile, !checkedProfile.trimmingCharacters(in: .whitespaces).isEmpty,
           PythonBridge.isRealHandle(typed) {
            lines.append(Note(text: checkedAgainstTheProfile, isProblem: false,
                              tooltip: checkedExplanation))
        }
        return lines
    }
}
