import Foundation

/// Names read out inside a sentence: "a", "a and b", "a, b and c".
///
/// One home for a joiner the codebase already spells ten times by hand, in
/// `PhotoTagSheetNote`, `DuplicateHandleMark`, `BackgroundWork`, `MissingMediaScan`,
/// `DesignStamp`, `DesignStaleScan`, `RecurringAccounts`, `DayRebuildRefusal`,
/// `ExportReadiness` and `GenerationFailureText`. Those copies do not agree:
/// some write "a, b and c" and some write "a, b, and c", so two sentences Dan
/// reads on the same screen can punctuate the same list differently.
///
/// New code uses this rather than adding an eleventh copy. Migrating the ten is
/// deliberately NOT done here, because it settles which convention is right and
/// that is a copy decision rather than a refactor, still to be put to Dan.
enum SentenceList {

    /// Empty for no items, so a caller that has nothing to name produces
    /// nothing rather than a sentence with a hole in it.
    ///
    /// The comma before "and" appears from THREE items only. Two are joined by
    /// "and" alone, which is the half a single joined() expression gets wrong,
    /// and two is the commonest length in this app.
    static func of(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        switch items.count {
        case 1:  return last
        case 2:  return items[0] + " and " + last
        default: return items.dropLast().joined(separator: ", ") + ", and " + last
        }
    }

    /// The verb for a list of this length, so a sentence built around it reads
    /// correctly without every caller writing the same conditional.
    static func verb(_ items: [String], singular: String, plural: String) -> String {
        items.count == 1 ? singular : plural
    }
}
