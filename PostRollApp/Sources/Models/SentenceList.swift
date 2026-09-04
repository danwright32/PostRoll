import Foundation

/// Names read out inside a sentence: "a", "a and b", "a, b and c".
///
/// The one home for a joiner this codebase used to spell ten times by hand, in
/// `PhotoTagSheetNote`, `DuplicateHandleMark`, `BackgroundWork`, `MissingMediaScan`,
/// `DesignStamp`, `DesignStaleScan`, `RecurringAccounts`, `DayRebuildRefusal`,
/// `ExportReadiness` and `GenerationFailureText`. Those copies did not agree:
/// five wrote "a, b and c" and five wrote "a, b, and c", so two sentences Dan
/// read on the same screen could punctuate the same list differently.
///
/// Dan settled it on 2026-08-28: the comma before "and" stays, and it appears
/// only from three items, so two are joined by "and" alone. All ten now come
/// here (#933), and `tests/test_one_list_joiner.py` is what stops an eleventh
/// being written: sharing a rule's DATA while copying the code that applies it
/// is not consolidation, because a change to how the data is applied then lands
/// in one copy only (L370).
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
