import Foundation

/// One way to tidy a value typed or pasted into a field before it is stored or
/// used as a key (#491).
///
/// `.whitespaces` does NOT include newlines, which is the whole problem. The new
/// event form trimmed with `.whitespaces` while its own validator used
/// `.whitespacesAndNewlines`, so a value pasted with a trailing newline passed
/// validation and was stored WITH the newline. Because org and venue are the
/// handle book's lookup keys, and the book normalised with `.whitespaces` too,
/// that org became a permanently separate key whose saved handles never
/// auto-filled again.
///
/// The recorded fix for exactly this trap was never swept across its siblings
/// (L30), so this exists to be the only spelling of it: a call site that reaches
/// for `trimmingCharacters` on a stored field is the defect returning.
enum FieldText {

    /// A value ready to store, or to key a lookup on.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the field says nothing, by the same rule.
    static func isBlank(_ raw: String) -> Bool {
        normalized(raw).isEmpty
    }

    /// A value for a field that is ONE line: the ends trimmed, and every line
    /// break inside it folded away (#688).
    ///
    /// `normalized` trims the ends only, so a break in the MIDDLE went through
    /// untouched. A single line `TextField` renders one as a gap that looks
    /// like a space, so nothing on screen says the value is broken, and these
    /// values are keys and copy: the handle book keys on the organisation, the
    /// event name reaches folder and file names, and a piece title reaches a
    /// caption a stranger reads.
    ///
    /// Folded to a space rather than deleted, because the everyday source is a
    /// title that WRAPPED across two printed lines: deleting the break would
    /// give "SymphonyNo. 5". Runs of whitespace collapse for the same reason,
    /// since a wrap often carries indentation with it.
    ///
    /// `.whitespacesAndNewlines` covers every shape named in the report,
    /// including the Unicode line and paragraph separators, so there is no
    /// second list of characters here to fall behind the first.
    ///
    /// Deliberately NOT the rule for every field. A piece's notes and a scene's
    /// description are prose, and line breaks are meaningful in both; applying
    /// this to a whole payload would flatten them.
    static func singleLine(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
