import Foundation

/// What the tagging sheet says when it is offering fewer people than the
/// programme has (#902).
///
/// Two performers carrying one handle collapse to a single chip. The dedupe is
/// deliberate and stays, because an account can only be tagged once. What was
/// missing is anybody being told: measured on Battery Dance Festival,
/// 2026-08-27, six performers produced five chips and the sheet said nothing,
/// so a person counting chips against the programme could not tell somebody
/// left out from somebody who was never there.
///
/// #901 put a warning on the Review screen. This is the sheet, which is where
/// the absence is actually noticed.
///
/// A pure type so the sentence can be asserted. The count and the list come
/// from the pass that built the chips, not from a second reading of the
/// performers (L107).
enum PhotoTagSheetNote {

    /// One sentence, or nothing when everybody is on the list.
    ///
    /// `dropped` names the rows, because a count on its own leaves the whole
    /// programme to be read by hand to find out who is missing (L80). It is
    /// the rows that were TAKEN OUT, never the ones that survived: naming a
    /// survivor sends somebody looking for a chip that is already there.
    ///
    /// A row with neither a name nor a handle is not counted at either end. It
    /// was never offerable, so reporting it would name a hole in the list that
    /// nothing can fill (L111).
    static func line(offered: Int, offerable: Int, dropped: [String]) -> String? {
        guard !dropped.isEmpty else { return nil }
        let who = list(dropped)
        let verb = dropped.count == 1 ? "shares" : "share"
        return "Offering \(offered) of \(offerable) people from this programme. "
            + "\(who) \(verb) an account with somebody already on the list, and "
            + "an account can only be tagged once."
    }

    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
