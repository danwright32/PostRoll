import Foundation

/// Which remembered audience figures are worth chasing (#289).
///
/// A figure goes stale after six months (`AccountStats.staleAfterDays`), but
/// that flag is only ever seen on the collaborator panel for a day that has been
/// expanded. An account tagged every month can go stale in March and nothing
/// says so until Dan happens to scroll to a post that tags them, by which point
/// the ranking has been quietly running on an old number.
///
/// So the answer is not "show every stale figure". Dan, 2026-08-10: "a lot of
/// the time I tag people once and never again." Measured across his 19 real
/// events the same day: 38 accounts ever tagged, 32 of them on exactly one
/// event. Asking for numbers on those is wasted effort, and thirty two requests
/// would bury the six that matter.
///
/// What is worth surfacing is an account that keeps coming back, because that is
/// the one whose number is both wrong and load-bearing. All six of Dan's are
/// venues and orgs: @carnegiehall across 6 events, then @dciny,
/// @everyvoicechoirs, @decodamusic, @lincolncenter and @greenwich_house.
///
/// Recurrence is DERIVED from the events rather than counted into the account
/// book as they are tagged. The events are what actually record who was tagged,
/// and a stored tally beside them would drift the first time one is edited or
/// deleted (L41). It also means this works on the events already on disk instead
/// of only on ones exported from here on.
enum RecurringAccounts {

    /// How many separate events an account has to appear on to count as one that
    /// keeps coming back. Two: the first time somebody returns is the moment
    /// their number stops being a one-off detail.
    static let minimumEvents = 2

    /// Why an account's figures need a moment.
    ///
    /// Two states, not one. Typing a number in for the first time and checking
    /// one that has drifted are different jobs, and a single lumped count tells
    /// Dan neither (L11).
    enum Need: Equatable {
        /// Tagged repeatedly and never counted, so the ranking cannot score it
        /// at all. Every one of Dan's six is in this state today.
        case neverCounted
        case stale(daysOld: Int)
    }

    /// One account worth a moment, and why.
    struct Attention: Equatable, Identifiable {
        var handle: String
        /// How many separate events tagged it. What makes a wrong number
        /// expensive, and what the list is ordered by.
        var eventCount: Int
        var need: Need

        var id: String { handle }
    }

    /// How many separate events tagged each account, keyed the way the book keys.
    ///
    /// Counted per event, not per tag: an account named in a photo tag, a day
    /// tag and the event handles of one week is one appearance, not three.
    /// Counting tags would make a single heavily tagged week look like a
    /// returning relationship.
    static func eventCounts(events: [Event]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for event in events {
            for key in Set(CaptionBlocks.accountsTagged(event: event).map(AccountBook.key))
            where !key.isEmpty {
                counts[key, default: 0] += 1
            }
        }
        return counts
    }

    /// Recurring accounts TAGGED ON ONE EVENT whose figures need attention,
    /// most load-bearing first.
    ///
    /// Two scopes, deliberately different, and the difference is the whole
    /// point (#1012, #1013). Recurrence is counted across `events`, the whole
    /// library, because appearing on several events is what makes an account
    /// one that keeps coming back. The ANSWER is then narrowed to the accounts
    /// `event` actually tags, because this is rendered on that event's export
    /// screen, between two banners that genuinely are about it.
    ///
    /// Dan, 2026-09-01: "why is it showing on events that don't include those
    /// accounts? like if it's at a random church why is it mentioning carnegie
    /// hall?" It was library-wide, and nothing in the sentence said so, so it
    /// inherited the page's scope by position and read as a claim about a
    /// church that has never tagged that account.
    ///
    /// Narrowing costs no coverage. An account with `minimumEvents` or more
    /// appearances is on that many events by definition, so it is still raised,
    /// on the events it is on, where the ask makes sense and the way in is
    /// beside it.
    ///
    /// `event` is required rather than optional. A default standing for "the
    /// whole library" would let a caller that forgot it silently get the
    /// behaviour this exists to remove, and a wrong scope reads as a working
    /// banner (L168).
    ///
    /// `stats` is a lookup rather than the book itself, so this can be exercised
    /// without a file on disk and called from wherever the figures have already
    /// been copied off the main actor.
    static func needingAttention(events: [Event],
                                 taggedOn event: Event,
                                 stats: (String) -> AccountStats?,
                                 asOf now: Date) -> [Attention] {
        // The same reader the counts are built from, so an account can never be
        // counted as recurring by one spelling and missed by another (L16).
        let onThisEvent = Set(CaptionBlocks.accountsTagged(event: event).map(AccountBook.key))
        var out: [Attention] = []
        for (key, count) in eventCounts(events: events)
        where count >= minimumEvents && onThisEvent.contains(key) {
            let known = stats(key)
            // A private account can never become rankable (#982). The figures
            // this banner asks for are visible only to approved followers, so
            // every appearance it makes here is a job nobody can finish, and a
            // list that always holds an item nobody can clear stops being read
            // (L36).
            if known?.isPrivate == true { continue }
            let need: Need
            switch known?.freshness(asOf: now) ?? .unknown {
            case .unknown:            need = .neverCounted
            case .stale(let daysOld): need = .stale(daysOld: daysOld)
            case .fresh:              continue
            }
            out.append(Attention(handle: key, eventCount: count, need: need))
        }
        // Most often tagged first, because that is what makes a wrong number
        // expensive. Handle alphabetically inside a tie so the list does not
        // reshuffle between reads for no reason.
        return out.sorted {
            $0.eventCount != $1.eventCount ? $0.eventCount > $1.eventCount : $0.handle < $1.handle
        }
    }

    /// One line for a screen Dan already passes, or nil when there is nothing
    /// to say.
    ///
    /// Names the accounts rather than only counting them, because a message that
    /// says how many without saying which leaves him nowhere to go (L80). Capped,
    /// so a long list does not become a paragraph.
    ///
    /// The scope is stated ONCE, at the front, so it governs both halves (#1012).
    /// The old wording, "tagged again and again", described a library-wide set
    /// while sitting on one event's screen, and a sentence with no scope in it
    /// is read as belonging to whatever surrounds it (L287). Putting the scope
    /// in the second clause instead would leave the first half of a two part
    /// message unscoped, which is the same defect in a smaller form.
    static let scopeLine = "Tagged on this event and coming up on your others: "

    static func summary(_ items: [Attention]) -> String? {
        guard !items.isEmpty else { return nil }
        let never = items.filter { $0.need == .neverCounted }
        let stale = items.filter { $0.need != .neverCounted }
        var parts: [String] = []
        if !never.isEmpty {
            parts.append("\(list(never)) \(never.count == 1 ? "has" : "have") "
                       + "no numbers yet")
        }
        if !stale.isEmpty {
            parts.append("\(list(stale)) \(stale.count == 1 ? "has numbers" : "have numbers") "
                       + "more than six months old")
        }
        return scopeLine + parts.joined(separator: ", and ") + "."
    }

    /// How many of the named accounts the message itself carries a way in for.
    static let namesShown = 3

    /// The accounts a control has to be offered for, in the order named.
    ///
    /// Every account the message names must be reachable from where it is named.
    /// The obvious place to send Dan, the collaborator list, is built from day
    /// and per-photo tags only, so a venue or org handle can never appear in it,
    /// and those are exactly the accounts this surfaces. Naming a target and
    /// then pointing at a screen it cannot be on is half a message (L80).
    ///
    /// Capped at what the message names, so it cannot promise a control for an
    /// account it did not mention.
    static func actionable(_ items: [Attention]) -> [Attention] {
        Array(items.prefix(namesShown))
    }

    // MARK: - How loudly to ask, per account

    /// How prominently to offer the numbers control beside one account.
    ///
    /// The collaborator panel offers it on every tagged account, and most of
    /// those are people Dan tags once and never again, so the ask that matters
    /// sits in a column of thirty that do not. Quieted, never removed: nothing
    /// here is impossible, and a control taken away because it is usually not
    /// worth it only ever stops the person who meant to use it (L54).
    enum Emphasis: Equatable { case quiet, prominent }

    static func emphasis(handle: String, in counts: [String: Int]) -> Emphasis {
        (counts[AccountBook.key(handle)] ?? 0) >= minimumEvents ? .prominent : .quiet
    }

    /// Why this row is worth a minute, or nil when it is not one of them.
    static func recurrenceNote(handle: String, in counts: [String: Int]) -> String? {
        let count = counts[AccountBook.key(handle)] ?? 0
        guard count >= minimumEvents else { return nil }
        return "Tagged on \(count) events"
    }

    /// At most three names, then how many more, so the line stays a line.
    private static func list(_ items: [Attention]) -> String {
        let names = items.prefix(namesShown).map { "@\($0.handle)" }
        let rest = items.count - names.count
        let joined = SentenceList.of(Array(names))
        return rest > 0 ? "\(joined) and \(rest) more" : joined
    }
}
