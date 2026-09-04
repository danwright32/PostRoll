import Foundation

/// Two rows of one programme carrying the same handle, or the same name.
///
/// Measured on Battery Dance Festival, 2026-08-27: a paste put
/// `@nanmdancecompany` onto "Ashley Liang Dance Company" as well as "NANM".
/// Nothing anywhere reported it, because every list built from the performers
/// is keyed on one of those two fields and each of them is right to hold a key
/// once. The tagging sheet offered five of the six performers, the caption
/// credited one account where two companies danced, and the credit check that
/// exists to catch a missing credit found the handle present and passed. The
/// handle book, keyed on the name, was one press of Continue away from
/// replacing the `@lotus_dance_fairy` it already held for Ashley Liang.
///
/// The collision can only be SEEN on the Review screen, where both rows are on
/// screen together, so it is derived once here and read by everything that
/// would otherwise collapse the two silently (L30: the class, not the
/// instance).
///
/// Both rows are marked rather than the later one. Which of them holds the bad
/// value is not something the app can know, and marking one would point at the
/// wrong company half the time.
enum DuplicateHandleMark {

    /// Who else on this programme carries this row's handle, and its name.
    ///
    /// Two lists rather than one flag: they are different mistakes with
    /// different remedies (a handle is retyped, a name means two rows are one
    /// performer), and clearing one does not clear the other.
    struct Mark: Equatable {
        var sameHandleAs: [String] = []
        var sameNameAs: [String] = []

        /// The line the row shows. Names the other rows, because a warning that
        /// a value repeats without saying where leaves the whole list to be
        /// read by hand (L80).
        var note: String {
            let handles = DuplicateHandleMark.list(sameHandleAs)
            let names = DuplicateHandleMark.list(sameNameAs)
            switch (sameHandleAs.isEmpty, sameNameAs.isEmpty) {
            case (true, true):   return ""
            case (false, true):  return "Same handle as \(handles)"
            case (true, false):  return "Same name as \(names)"
            case (false, false):
                // The ordinary case is one row repeated whole, which reads as
                // one sentence. Two different rows need two.
                if sameHandleAs == sameNameAs { return "Same name and handle as \(handles)" }
                return "Same name as \(names). Same handle as \(handles)"
            }
        }
    }

    /// The longer version, for the tooltip.
    static let explanation =
        "Two performers on this program carry the same details, so every list "
        + "built from them keeps one and drops the other: the tag suggestions, "
        + "the caption credits, and the saved handles. Correct whichever row is "
        + "wrong before continuing."

    /// Every row that repeats another's handle or name, keyed by performer.
    ///
    /// A row missing from the result is a row with nothing to report, so an
    /// empty result means a clean programme.
    static func marks(in performers: [Performer]) -> [UUID: Mark] {
        var byHandle: [String: [Int]] = [:]
        var byName: [String: [Int]] = [:]

        for (index, performer) in performers.enumerated() {
            let handle = performer.handle.trimmingCharacters(in: .whitespaces)
            // The same predicate the tag list and the caption credits use, so
            // the three agree on what counts as a handle at all. A sentinel
            // like "none" is not one, and two rows that both lack a handle
            // share nothing (L118: one word, one unit).
            if PythonBridge.isRealHandle(handle) {
                byHandle[CaptionBlocks.bareUsername(handle).lowercased(), default: []].append(index)
            }
            // Keyed exactly as HandleBook keys its entries, because the book is
            // what a repeated name actually damages.
            let name = FieldText.normalized(performer.name).lowercased()
            if !name.isEmpty { byName[name, default: []].append(index) }
        }

        func others(_ groups: [String: [Int]], _ index: Int) -> [Int] {
            for group in groups.values where group.contains(index) {
                return group.filter { $0 != index }
            }
            return []
        }

        var marks: [UUID: Mark] = [:]
        for (index, performer) in performers.enumerated() {
            let handleTwins = others(byHandle, index)
            let nameTwins = others(byName, index)
            guard !handleTwins.isEmpty || !nameTwins.isEmpty else { continue }
            marks[performer.id] = Mark(
                sameHandleAs: handleTwins.map { label(performers[$0]) },
                sameNameAs: nameTwins.map { label(performers[$0]) })
        }
        return marks
    }

    /// How another row is referred to. Its name, or its handle when the name is
    /// the field that is blank.
    private static func label(_ performer: Performer) -> String {
        let name = FieldText.normalized(performer.name)
        return name.isEmpty ? performer.handle.trimmingCharacters(in: .whitespaces) : name
    }

    private static func list(_ items: [String]) -> String { SentenceList.of(items) }
}
