import Foundation

/// Whether the stored Insights numbers were imported before the Meta export
/// timezone correction, and what to say when they were (#549, from #487).
///
/// The Meta CSV publish times are Pacific, not New York, so every posting time
/// analysis produced before that fix reads three hours early. New imports are
/// correct; the ones already on disk are not, and a three hour error looks
/// exactly like a real number. The screen would otherwise report a peak posting
/// hour of noon when the measured peak is 3pm, with the same confidence either
/// way.
///
/// ## Why this is keyed on the import date, not on the stored times
///
/// The obvious detection, noticing that a stored post's time carries no
/// timezone offset, cannot work. `AnalyticsStore` re-encodes the whole file with
/// `.iso8601` on every save, so a naive time imported before the fix was
/// rewritten as an absolute instant the first time anything saved the store.
/// The tell is already gone from analytics.json.
///
/// A guard built on it would find zero stale posts and report all clear, which
/// is worse than no guard: it would confirm the numbers are fine at exactly the
/// moment they are not (L133, L98).
enum AnalyticsStaleness {

    /// The instant the timezone correction reached main, rounded up to the hour.
    ///
    /// The fix merged at 2026-08-14T02:43:25Z. Rounding UP rather than down is
    /// deliberate: the app runs the Python from the checkout, so the exact
    /// moment the corrected reader started running depends on when the working
    /// tree held it. Erring later costs at worst a warning about a good import
    /// made inside a seventeen minute window; erring earlier would let a genuinely
    /// wrong import through with nothing said, and silence is the failure this
    /// exists to prevent.
    static let timezoneCorrection = Date(timeIntervalSince1970: 1_786_676_400) // 2026-08-14T03:00:00Z

    /// True when the numbers on screen were produced by the old reading.
    ///
    /// Both stale cases fail toward warning: an import recorded before the fix,
    /// and an import with no recorded date at all, which means it predates the
    /// `lastImport` field and is therefore older still.
    ///
    /// The empty case is checked first and separately. A store with nothing in
    /// it has nothing wrong with it, and without this the nil branch would fire
    /// on a first launch and tell Dan his numbers are wrong before he has any.
    static func isStale(postCount: Int, lastImport: Date?) -> Bool {
        guard postCount > 0 else { return false }
        guard let lastImport else { return true }
        return lastImport < timezoneCorrection
    }

    /// One notice, naming the control that clears it.
    ///
    /// It sits with the Import CSV button rather than only describing it,
    /// because advice that names no action the person can take leaves them
    /// exactly where they were (L111). It also says what is wrong in hours, so
    /// Dan can judge whether it matters to the question he is asking, rather
    /// than reading a vague "these may be out of date".
    static let notice =
        "These numbers were imported before PostRoll corrected the timezone on Meta's export, "
        + "so every posting time below reads three hours early. Import CSV again to fix them."
}
