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
}
