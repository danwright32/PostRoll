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

    /// Recurring accounts whose figures need attention, most load-bearing first.
    ///
    /// `stats` is a lookup rather than the book itself, so this can be exercised
    /// without a file on disk and called from wherever the figures have already
    /// been copied off the main actor.
    static func needingAttention(events: [Event],
                                 stats: (String) -> AccountStats?,
                                 asOf now: Date) -> [Attention] {
        var out: [Attention] = []
        for (key, count) in eventCounts(events: events) where count >= minimumEvents {
            let need: Need
            switch stats(key)?.freshness(asOf: now) ?? .unknown {
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
    static func summary(_ items: [Attention]) -> String? {
        guard !items.isEmpty else { return nil }
        let never = items.filter { $0.need == .neverCounted }
        let stale = items.filter { $0.need != .neverCounted }
        var parts: [String] = []
        if !never.isEmpty {
            parts.append("\(list(never)) \(never.count == 1 ? "is" : "are") tagged again "
                       + "and again with no numbers yet")
        }
        if !stale.isEmpty {
            parts.append("\(list(stale)) \(stale.count == 1 ? "has numbers" : "have numbers") "
                       + "more than six months old")
        }
        return parts.joined(separator: ", and ") + ". Add them from the collaborator "
             + "list on any day that tags them."
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
        let names = items.prefix(3).map { "@\($0.handle)" }
        let rest = items.count - names.count
        let joined: String
        switch names.count {
        case 1:  joined = names[0]
        case 2:  joined = "\(names[0]) and \(names[1])"
        default: joined = names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
        return rest > 0 ? "\(joined) and \(rest) more" : joined
    }
}
