import Foundation

/// Which accounts an automatic figures fetch should ask Meta about (#1004).
///
/// The fetch fires when an event's handle list settles, and the first question
/// is which of those handles are worth a call. Meta's allowance is a rolling
/// hour and 122 handles spent about a quarter of it, so asking about
/// everything every time the list changes would spend the hour on accounts
/// nothing has changed about.
///
/// Pure, and separate from the manager that runs the fetch, because this is
/// the part with the decisions in it and the rest is a debounce and a
/// subprocess.
enum AccountFetchDue {

    /// How many failures in a row before an account is left alone for a while.
    ///
    /// Three. Enough that a bad afternoon does not freeze an account out, few
    /// enough that a handle which always fails costs three calls rather than
    /// one per settle forever. The refusal is not permanent: it lifts once the
    /// record is old, because whatever was wrong may have been fixed and an
    /// account written off for good is the unrecoverable state the non terminal
    /// outcomes exist to avoid (L248, L365).
    static let maximumAttempts = 3

    /// The attempt count after one fetch ends with this outcome.
    ///
    /// Cleared by anything that is not worth retrying, which includes success:
    /// a count left standing after a good fetch means the next failure starts
    /// from an old number and the account is frozen out early.
    static func attemptsAfter(_ outcome: AccountStats.FetchOutcome?,
                              wasAt attempts: Int) -> Int {
        guard let outcome, outcome.isWorthRetrying else { return 0 }
        return attempts + 1
    }

    /// Every account an event could tag, from both places one can be stored.
    ///
    /// `CaptionBlocks.accountsTagged` answers what a POST tags, which is the
    /// right question for a caption and the wrong one here: a handle accepted
    /// from a lookup lands on a PERFORMER and does not reach a day's tag list
    /// until the photos are assigned. Fetching only what a post tags would
    /// therefore miss the account at exactly the moment it was added, which is
    /// the moment the fetch exists to catch.
    ///
    /// One reader for all three trigger sites, so they cannot come to disagree
    /// about which accounts an event has.
    static func accounts(in event: Event) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for handle in CaptionBlocks.accountsTagged(event: event)
            + ((event.ocrResult?.performers ?? []).map(\.handle)) {
            let name = CaptionBlocks.bareUsername(handle)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// The handles worth fetching, in the order they arrived.
    ///
    /// Order preserved rather than sorted, so a run cut short by the allowance
    /// has asked about the accounts this event actually leads with rather than
    /// an arbitrary slice (L343).
    static func handles(from raw: [String],
                        stats: (String) -> AccountStats?,
                        asOf now: Date) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            // The same reader every other surface asks (#981), so a sentinel
            // the caption pipeline wrote can never become a Meta call.
            guard PythonBridge.isRealHandle(value) else { continue }
            let key = AccountBook.key(value)
            guard seen.insert(key).inserted else { continue }
            guard isDue(stats(key), asOf: now) else { continue }
            out.append(key)
        }
        return out
    }

    /// Whether asking about this account again could tell us anything new.
    ///
    /// Its OWN predicate, deliberately not `freshness`. `freshness` answers
    /// `.unknown` for a record with no engagement data, and `.unknown` is not
    /// stale, so a record left behind by a network failure could never be
    /// refetched by the staleness path: it would be asked about never again,
    /// which is the opposite of what a transient failure deserves.
    static func isDue(_ stats: AccountStats?, asOf now: Date) -> Bool {
        // Never asked about at all.
        guard let stats else { return true }

        switch stats.outcome {
        case .none:
            // Figures somebody typed in, and no fetch has ever run. Worth one:
            // the fetch adds what typing cannot, which is the stable id, the
            // post mix, and whether Meta will answer for this account at all.
            return true
        case .some(let outcome) where outcome.isWorthRetrying:
            // Bounded. Every attempt against a metered API spends the thing
            // that is running out, and a handle which always fails would ask
            // on every settle forever (L365).
            //
            // The bound lifts once the record is old, so this is a pause and
            // not a verdict: whatever was wrong may have been fixed, and an
            // account frozen out for good on three bad afternoons is the same
            // unrecoverable state the non terminal outcomes exist to avoid.
            return stats.fetchAttempts < maximumAttempts
                || isPastTheStaleLine(stats, asOf: now)
        case .some:
            // Terminal. A personal account does not become a professional one
            // because somebody tagged it again, and asking spends the allowance
            // to be told the same thing. Only age reopens it.
            return isPastTheStaleLine(stats, asOf: now)
        }
    }

    /// Whether a record is old enough to be worth confirming.
    ///
    /// Read off the stamp rather than through `freshness`, which needs
    /// engagement data and so answers `.unknown` for exactly the records this
    /// is about: an account Meta refused has a follower count and nothing else,
    /// and one it reported on may have a withheld like count.
    ///
    /// The line itself is `AccountStats.staleAfterDays`, named there rather
    /// than spelled again here, so the age at which a figure stops being
    /// trusted and the age at which it is refetched cannot drift apart.
    private static func isPastTheStaleLine(_ stats: AccountStats,
                                           asOf now: Date) -> Bool {
        // No stamp at all is not a fresh record. Something wrote an outcome
        // without one, and the honest answer to "how old is this" is that
        // nobody knows, which is a reason to ask rather than to leave it.
        guard let recordedOn = stats.recordedOn else { return true }
        let age = now.timeIntervalSince(recordedOn)
        // A stamp in the future is a clock change, not an ancient figure.
        guard age > 0 else { return false }
        return Int((age / 86_400).rounded(.down)) > AccountStats.staleAfterDays
    }
}
