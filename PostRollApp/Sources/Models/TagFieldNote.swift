import Foundation

/// What a tag field says about the values typed into it (#919).
///
/// #912 made a value that is not a usable handle become a NAME credit instead
/// of a broken mention, and #917 stopped it reaching the exported tag list at
/// all. Both are the right outcome, and both happen in silence, so somebody
/// typing a company name into a tag field is never told the account was not
/// usable and the credit will read as words rather than a tag.
///
/// The performer rows have said this since #899, in `PerformerRowNotes`. These
/// fields carry the same value through the same rule and said nothing, so one
/// surface taught what the other hid (L11).
///
/// A pure type so the sentence can be asserted, the way `PhotoTagSheetNote` is.
/// It reads `TypedCredit`, which is the same routing the value itself takes, so
/// the field cannot promise an outcome the value does not get (L144).
enum TagFieldNote {

    /// One line for the whole field, or nothing when every value is taggable.
    ///
    /// A name and a placeholder are DIFFERENT outcomes and get their own
    /// sentence: one is credited in the caption by name, the other reaches
    /// nothing at all. Folding them together would tell somebody their
    /// placeholder will be credited, which is a promise nothing keeps (L11).
    ///
    /// Values are named, never counted. A count leaves the field to be read by
    /// hand to work out which entry it means, and the field is where the
    /// correction happens (L80).
    static func line(for raw: String) -> String? {
        var names: [String] = []
        var ignored: [String] = []

        for piece in raw.split(separator: ",") {
            // What was typed, not what the routing extracts from it: this
            // sentence exists to be matched against the field, so it has to
            // quote the field.
            let typed = piece.trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else { continue }
            switch TypedCredit.read(typed) {
            case .mention: continue
            case .name:    names.append(typed)
            case .nothing: ignored.append(typed)
            }
        }

        var sentences: [String] = []
        if !names.isEmpty {
            let verb = SentenceList.verb(names, singular: "is not an Instagram handle",
                                         plural: "are not Instagram handles")
            let pronoun = names.count == 1 ? "it" : "they"
            sentences.append("\(SentenceList.of(names)) \(verb), so \(pronoun) "
                             + "will be credited by name rather than tagged.")
        }
        if !ignored.isEmpty {
            let verb = SentenceList.verb(ignored, singular: "is a placeholder",
                                         plural: "are placeholders")
            let pronoun = ignored.count == 1 ? "it" : "they"
            sentences.append("\(SentenceList.of(ignored)) \(verb), so \(pronoun) "
                             + "will be ignored.")
        }

        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
