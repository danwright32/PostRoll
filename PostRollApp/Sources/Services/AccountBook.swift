import Foundation

/// What is known about one tagged account's audience.
///
/// Every figure is optional, and that is the point (#279). An account nobody
/// has counted yet must read as unknown rather than as zero: scored as zero it
/// sorts to the bottom of a collaborator ranking as though it had been measured
/// and found wanting, which is a claim the app has no basis for. Zero itself is
/// a real measurement and is kept.
struct AccountStats: Codable, Equatable, Sendable {
    /// Followers. Secondary to the engagement rate in any ranking, because a
    /// large dead audience reaches nobody.
    var followers: Int?
    /// Typical likes on one of that account's own posts.
    var likes: Int?
    /// Typical comments on one of that account's own posts. Weighted more
    /// heavily than likes wherever these are scored: a comment is a stronger
    /// signal of a live audience.
    var comments: Int?
    /// When these figures were entered. Numbers age, and a ranking built on a
    /// two year old count looks exactly as confident as one built on today's.
    var recordedOn: Date?

    // MARK: - Where each figure came from (#1003)
    //
    // Known and accepted, documented rather than defended. `init(from:)` reads
    // the keys it knows and ignores the rest, which is what lets a record
    // written by a NEWER build survive a read by an older one. The cost is the
    // other direction: running an older build over this book decodes every
    // record without these fields, and `noteTagged` runs on every export
    // (`ExportManager.swift:448`), so one export under a downgraded build
    // writes them all back stripped of provenance.
    //
    // Not defended against, because the alternative is refusing to load a book
    // an old build wrote, which turns a downgrade into an app that cannot open
    // its own data. The figures themselves survive; what is lost is where they
    // came from, and a refetch restores it.

    /// Where one stored figure came from.
    ///
    /// Three values, not two. A figure Dan typed and a figure Meta reported
    /// are different claims, and an account that ANSWERED while withholding
    /// one figure is a third thing again: `hidden` is not absent and is
    /// certainly not zero, and it must never reach the arithmetic as one
    /// (#1032, L507).
    enum FigureSource: String, Codable, Equatable, Sendable {
        case typed
        case measured
        case hidden
    }

    /// How one fetch ended, in the seven states the Python side reports.
    ///
    /// Stored so an account that cannot be measured is distinguishable from one
    /// nobody has looked at, which is the whole of why the fetch has seven
    /// outcomes rather than two. Mirrors `postroll.ai.account_numbers.Outcome`,
    /// plus one state only this side can reach.
    enum FetchOutcome: String, Codable, Equatable, Sendable {
        case measured
        case notProfessional = "not_professional"
        case noSuchAccount = "no_such_account"
        case couldNotClassify = "could_not_classify"
        case rateLimited = "rate_limited"
        case networkFailed = "network_failed"
        case tokenRejected = "token_rejected"
        /// The handle now resolves to a DIFFERENT Instagram account, so the
        /// figures that came back describe somebody else. Only this side can
        /// see it, because only this side remembers the previous id.
        case handleChangedHands = "handle_changed_hands"

        /// Whether asking again could produce a different answer.
        var isWorthRetrying: Bool {
            switch self {
            case .measured, .notProfessional, .noSuchAccount:
                return false
            case .couldNotClassify, .rateLimited, .networkFailed, .tokenRejected,
                 .handleChangedHands:
                return true
            }
        }
    }

    var followersSource: FigureSource?
    var likesSource: FigureSource?
    var commentsSource: FigureSource?
    /// How the last fetch ended, or nil if there has never been one.
    var outcome: FetchOutcome?
    /// Meta's stable id for this account.
    ///
    /// `business_discovery.username(...)` looks up by a MUTABLE display name,
    /// so without this a renamed handle silently attributes one account's
    /// audience to whoever holds the name next.
    var instagramID: String?
    /// How many of the sampled posts were reels, and how many were feed posts.
    ///
    /// Read by `mixNote`. Measured on the 2026-08-29 sample: reels drew 1.29x
    /// feed likes at the median and 11 of 46 accounts differed by more than
    /// double, so a figure that jumps between fetches is often what the account
    /// posted rather than who is watching.
    var reels: Int?
    var feed: Int?
    /// The account answered and kept its like count back (#1032).
    ///
    /// A THIRD state, not a missing value and not a measurement. Folded into a
    /// score as zero, an account doing perfectly well is scored identically to
    /// one measured and found dead (L507). Measured on the committed
    /// population: 2 of 122 accounts withhold it.
    var likesAreHidden: Bool { likesSource == .hidden }

    /// How many times a fetch of this account has failed in a row (#1004).
    ///
    /// Zero after any success. The transient outcomes are deliberately not
    /// terminal, because writing an account off on an error nobody understood
    /// has no way back, and the cost of that is a handle which always fails
    /// being asked about on every settle forever against an API metered by the
    /// hour. This is what bounds it.
    ///
    /// Kept here rather than in the fetch, which answers about one account and
    /// remembers nothing.
    var fetchAttempts: Int = 0

    // MARK: - What came of the invites actually sent (#986)
    //
    // The ranking predicted reach and then never learned what came of it, so an
    // account that declines every week went on consuming one of only five slots
    // with nowhere to record that it had declined.
    //
    // Counts rather than a single verdict: one refusal is not a policy, and an
    // account that accepted twice and declined once has said something
    // different from one that has only ever refused. Entered by hand on the
    // numbers form, because Instagram tells Dan days after the post and no API
    // reports it.

    /// How many collaborator invites this account has accepted.
    var acceptedInvites: Int = 0
    /// How many it has declined, or left unanswered long enough to count as one.
    var declinedInvites: Int = 0

    /// Whether the record says this account tends to refuse.
    ///
    /// Deliberately a comparison rather than a threshold. Nobody has recorded a
    /// single outcome yet, so a fixed number would be one measured against
    /// nothing (L172); this is inert while both counts are zero, fires on the
    /// first unanswered invite, and is undone by one acceptance.
    var declinesOutweighAccepts: Bool { declinedInvites > acceptedInvites }

    /// Marked as never worth inviting, by hand (#1271).
    ///
    /// Not a ranking problem. However good the figures, Dan has decided the
    /// invite will not be sent, so a slot spent on this account is wasted and
    /// offering it again every week asks a question he has already answered.
    ///
    /// A mark on the ACCOUNT rather than a list of names inside the ranking: a
    /// list maintained by hand beside the data it describes is exempt from
    /// every check and cannot be changed without a build (L41).
    var neverInvite: Bool = false

    /// Marked private by hand (#982).
    ///
    /// Not detectable from the logged out page: an account serving a normal
    /// page with its follower count and no marker was verified on 2026-08-29,
    /// so the manual mark is the only mechanism there is.
    var isPrivate: Bool = false

    /// True only when there is enough to compute an engagement rate.
    ///
    /// Followers alone cannot: the rate is interactions over followers, so a
    /// record missing either half is not rankable and must say so rather than
    /// producing a number from a hole.
    var hasEngagementData: Bool {
        guard let followers, followers > 0 else { return false }
        return likes != nil || comments != nil
    }

    /// Decoded field by field so a record written by an older build survives
    /// being read by a newer one. Without this a single added field makes the
    /// whole file fail to decode, which is how saved data gets wiped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        followers       = try c.decodeIfPresent(Int.self,  forKey: .followers)
        likes           = try c.decodeIfPresent(Int.self,  forKey: .likes)
        comments        = try c.decodeIfPresent(Int.self,  forKey: .comments)
        recordedOn      = try c.decodeIfPresent(Date.self, forKey: .recordedOn)
        // Through the raw value, for the reason spelled out under `outcome`
        // below: an enum this build has no case for would otherwise throw and
        // take every account's figures with it. The rule is the same for all
        // four of these, so it is applied to all four rather than to the one a
        // test happened to be written about (L30).
        followersSource = FigureSource(rawValue:
            try c.decodeIfPresent(String.self, forKey: .followersSource) ?? "")
        likesSource     = FigureSource(rawValue:
            try c.decodeIfPresent(String.self, forKey: .likesSource) ?? "")
        commentsSource  = FigureSource(rawValue:
            try c.decodeIfPresent(String.self, forKey: .commentsSource) ?? "")
        // Decoded through its RAW value, not as the enum. `decodeIfPresent` on
        // an enum throws on a raw value it has no case for, and AccountRecord
        // lets that propagate, so one record carrying an outcome a newer build
        // wrote would fail the whole file and take every account's figures with
        // it. The rest of this decoder exists so an old record survives a new
        // build; this is the other direction, and it was fatal rather than
        // lossy (L337).
        //
        // An outcome nothing here understands reads as NO outcome, which is
        // the honest answer and the retryable one: the alternative is guessing
        // at a state and possibly never asking about that account again.
        outcome         = FetchOutcome(rawValue:
            try c.decodeIfPresent(String.self, forKey: .outcome) ?? "")
        instagramID     = try c.decodeIfPresent(String.self, forKey: .instagramID)
        reels           = try c.decodeIfPresent(Int.self, forKey: .reels)
        feed            = try c.decodeIfPresent(Int.self, forKey: .feed)
        isPrivate       = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        neverInvite     = try c.decodeIfPresent(Bool.self, forKey: .neverInvite) ?? false
        acceptedInvites = try c.decodeIfPresent(Int.self, forKey: .acceptedInvites) ?? 0
        declinedInvites = try c.decodeIfPresent(Int.self, forKey: .declinedInvites) ?? 0
        fetchAttempts   = try c.decodeIfPresent(Int.self, forKey: .fetchAttempts) ?? 0
    }

    init(followers: Int? = nil, likes: Int? = nil, comments: Int? = nil,
         recordedOn: Date? = nil,
         followersSource: FigureSource? = nil,
         likesSource: FigureSource? = nil,
         commentsSource: FigureSource? = nil,
         outcome: FetchOutcome? = nil,
         instagramID: String? = nil,
         reels: Int? = nil, feed: Int? = nil,
         isPrivate: Bool = false,
         neverInvite: Bool = false,
         acceptedInvites: Int = 0,
         declinedInvites: Int = 0,
         fetchAttempts: Int = 0) {
        self.followers = followers
        self.likes = likes
        self.comments = comments
        self.recordedOn = recordedOn
        self.followersSource = followersSource
        self.likesSource = likesSource
        self.commentsSource = commentsSource
        self.outcome = outcome
        self.instagramID = instagramID
        self.reels = reels
        self.feed = feed
        self.isPrivate = isPrivate
        self.neverInvite = neverInvite
        self.acceptedInvites = acceptedInvites
        self.declinedInvites = declinedInvites
        self.fetchAttempts = fetchAttempts
    }

    // MARK: - Merging, never rebuilding (#1003)

    /// This record with `incoming`'s stated figures written over it.
    ///
    /// A COPY of what is already stored, with only the fields the incoming
    /// record actually carries replaced. Rebuilding from a handful of values is
    /// how typing a follower count into the sheet came to erase the fetch
    /// outcome, the stable id and the private mark, silently making that
    /// account unrankable again (L510).
    ///
    /// A nil figure on `incoming` means "this fetch says nothing about it",
    /// not "this figure is now unknown". The only way to clear a figure is to
    /// type an empty field, which goes through `AccountBook.record`.
    func merged(with incoming: AccountStats) -> AccountStats {
        var merged = self
        if incoming.followers != nil {
            merged.followers = incoming.followers
            merged.followersSource = incoming.followersSource
        }
        if incoming.likes != nil || incoming.likesSource == .hidden {
            merged.likes = incoming.likes
            merged.likesSource = incoming.likesSource
        }
        if incoming.comments != nil {
            merged.comments = incoming.comments
            merged.commentsSource = incoming.commentsSource
        }
        if let outcome = incoming.outcome { merged.outcome = outcome }
        if let id = incoming.instagramID { merged.instagramID = id }
        if incoming.reels != nil || incoming.feed != nil {
            merged.reels = incoming.reels
            merged.feed = incoming.feed
        }
        if let recordedOn = incoming.recordedOn { merged.recordedOn = recordedOn }
        // isPrivate and neverInvite are never carried by a fetch: they are
        // marks Dan makes by hand and nothing else may clear them (#982, #1271).
        //
        // The attempt count moves with the OUTCOME, so a success clears it and
        // a failure carries it forward. Without this the bound is a field
        // nothing increments and the retry is unbounded with a number beside
        // it (L46).
        if let outcome = incoming.outcome {
            merged.fetchAttempts = AccountFetchDue.attemptsAfter(outcome,
                                                                 wasAt: fetchAttempts)
        }
        return merged
    }

    // MARK: - Explaining a figure that moved (#1003)

    /// How much a figure has to move before it is worth explaining.
    static let materialMove = 0.25

    /// How much the reels share has to move before it can be the explanation.
    static let materialMixShift = 0.5

    /// Said when a refetch moved a figure AND the account changed what it posts.
    ///
    /// Nil the rest of the time, in both directions, and both matter. A note on
    /// every jump would explain away real audience growth, which is the thing
    /// the ranking exists to notice; a note on every mix change would be noise
    /// on an ordinary refetch.
    ///
    /// Measured on the 2026-08-29 sample: reels drew 1.29x feed likes at the
    /// median, and 11 of 46 accounts differed by more than double, so the mix
    /// really can carry a figure on its own.
    static func mixNote(before: AccountStats, after: AccountStats) -> String? {
        guard let wasLikes = before.likes, wasLikes > 0, let nowLikes = after.likes,
              let wasShare = before.reelsShare, let nowShare = after.reelsShare
        else { return nil }
        let moved = abs(Double(nowLikes - wasLikes) / Double(wasLikes))
        guard moved >= materialMove, abs(nowShare - wasShare) >= materialMixShift
        else { return nil }
        let direction = nowShare > wasShare ? "more reels" : "fewer reels"
        return "This figure moved \(Int((moved * 100).rounded()))% and the account "
             + "posted \(direction) than last time, so some of the change is what "
             + "it posted rather than who is watching."
    }

    /// What share of the sampled posts were reels, or nil if no mix was stored.
    ///
    /// Nil rather than zero for an absent mix. Every record written before the
    /// mix existed has none, and reading those as no reels at all would look
    /// like a total shift on the first fetch that records one.
    var reelsShare: Double? {
        guard let reels, let feed, reels + feed > 0 else { return nil }
        return Double(reels) / Double(reels + feed)
    }
}

// MARK: - Ageing (#280)

extension AccountStats {

    /// How old a figure may be before a suggestion built on it has to say so.
    ///
    /// Six months. Follower counts drift slowly, but an engagement rate can
    /// halve in a season when an account changes what it posts or the platform
    /// changes what it shows, and the ranking cannot tell the difference. Named
    /// here rather than typed at each use, so the one place to argue with it is
    /// the one place it is defined.
    static let staleAfterDays = 180

    /// Whether a figure is recent enough to be trusted without a caveat.
    ///
    /// Three answers, not two. "Never counted" and "counted a long time ago"
    /// are different facts: the second is still worth ranking on, the first is
    /// not rankable at all, and collapsing them would score an unmeasured
    /// account as though it had been measured.
    enum Freshness: Equatable {
        /// No figures, or figures with no date, which is the same thing here: a
        /// number with no stamp cannot be called recent without asserting
        /// something nothing measured.
        case unknown
        case fresh
        case stale(daysOld: Int)

        var isStale: Bool { if case .stale = self { return true }; return false }
    }

    func freshness(asOf now: Date) -> Freshness {
        guard hasEngagementData, let recordedOn else { return .unknown }
        let age = now.timeIntervalSince(recordedOn)
        // A stamp in the future is a clock change, not an ancient figure, and
        // must not produce a negative age in the label.
        guard age > 0 else { return .fresh }
        let daysOld = Int((age / 86_400).rounded(.down))
        return daysOld > Self.staleAfterDays ? .stale(daysOld: daysOld) : .fresh
    }

    // MARK: - How far counted (#977)

    /// What is known about this account, in the three states that differ.
    ///
    /// Rankability has three answers and only two were represented. Dan entered
    /// a follower count for an account, left the other two fields empty and
    /// saved; the row still read "Not counted yet", and so did the foot of the
    /// dialog with the number sitting in the field above it.
    ///
    /// The rule that a follower count alone cannot produce an engagement rate
    /// is correct and does not change. What changes is that "nobody has ever
    /// opened this" and "this needs one more figure" are different facts with
    /// different remedies, and reporting that nothing was entered immediately
    /// after something was is the state most likely to make somebody enter it
    /// again.
    enum Countedness: Equatable {
        /// Nothing at all, or nothing that could be ranked or assumed from.
        case neverCounted
        /// A follower count and no engagement figures, and no reason to assume
        /// any. One more figure away from ranking.
        case followersOnly
        /// Enough to rank, whether measured or assumed.
        case counted
        /// Marked private by hand (#982). A permanent property of the account,
        /// not a job waiting to be done: the per post figures the other states
        /// ask for are visible only to approved followers, so the remedy
        /// `followersOnly` names cannot be carried out here (L111).
        case privateAccount
    }

    var countedness: Countedness {
        if hasEngagementData { return .counted }
        // An account Meta refused, or one that withheld its like count, is
        // scored on an assumption and IS ranked (#1005, #1032). Telling those
        // to add likes would name a remedy that changes nothing.
        if likesAreHidden { return .counted }
        if outcome == .notProfessional || outcome == .noSuchAccount {
            return followers ?? 0 > 0 ? .counted : .neverCounted
        }
        // After every state that can still rank, before the two that ask for a
        // figure (#982). What reaches here can never be counted: the per post
        // likes and comments are visible only to approved followers, so
        // `followersOnly`'s remedy names a step nobody can take (L111).
        if isPrivate { return .privateAccount }
        if let followers, followers > 0 { return .followersOnly }
        return .neverCounted
    }

    /// The requirement the numbers form has to state BEFORE the fields.
    ///
    /// The old copy described three independent optional fields. That is true
    /// of each field alone and says nothing about the requirement binding
    /// them, so somebody who knows a follower count fills in the one field
    /// they have, saves, and gets nothing, with no statement anywhere that the
    /// entry was insufficient.
    ///
    /// Held here rather than in the view so the sentence the form shows and the
    /// label the row shows cannot come to disagree about the same rule.
    static let numbersFormRequirement =
        "Followers alone cannot rank an account: the ranking needs likes or "
        + "comments too. Leave a field empty if you do not know it, which "
        + "stores as not counted rather than as zero."

    /// What to show beside the numbers, wherever they are shown.
    ///
    /// Never a blank: a gap where a figure goes reads as a number that failed
    /// to load rather than one nobody has entered.
    func freshnessLabel(asOf now: Date) -> String {
        // Three answers, not two (#977). A record holding a follower count and
        // a date is not one nobody has opened, and it needs a different thing
        // done to it.
        switch countedness {
        case .neverCounted:  return "Not counted yet"
        case .followersOnly: return "Followers only, add likes or comments to rank"
        case .privateAccount: return "Private, so its posts cannot be counted"
        case .counted:       break
        }
        guard let recordedOn else { return "Not counted yet" }
        let stamp = Self.stampFormatter.string(from: recordedOn)
        switch freshness(asOf: now) {
        case .stale(let daysOld):
            return "Entered \(stamp), \(daysOld) days ago, stale"
        default:
            return "Entered \(stamp)"
        }
    }

    /// Fixed POSIX locale, so the string a test pins is the string Dan sees.
    /// A host-locale formatter would render differently on his Mac than in CI.
    nonisolated(unsafe) private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}

/// One account the app has seen, whether or not anyone has counted it.
struct AccountRecord: Codable, Equatable, Identifiable, Sendable {
    /// The spelling to show. Instagram handles are case insensitive, but people
    /// care how theirs reads, so the display form is kept even though the key
    /// that identifies the record is folded.
    var handle: String
    var stats: AccountStats
    /// When this account was last tagged on an event.
    ///
    /// Read by `all`, which orders the book newest tag first, so the accounts
    /// Dan has worked with most recently come up first in the collaborator
    /// panel. That ordering is the whole of what it does today; the comment
    /// here used to promise a browsable "everyone ever tagged" screen that has
    /// never existed, which is a field reading as wired to something it is not
    /// (#490, L46).
    var lastTaggedOn: Date?

    /// Keyed on the bare username, folded, so `@name`, `name` and a pasted
    /// profile URL are one person rather than three.
    var id: String { AccountBook.key(handle) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle       = try c.decodeIfPresent(String.self, forKey: .handle) ?? ""
        stats        = try c.decodeIfPresent(AccountStats.self, forKey: .stats) ?? AccountStats()
        lastTaggedOn = try c.decodeIfPresent(Date.self, forKey: .lastTaggedOn)
    }

    init(handle: String, stats: AccountStats = AccountStats(), lastTaggedOn: Date? = nil) {
        self.handle = handle
        self.stats = stats
        self.lastTaggedOn = lastTaggedOn
    }
}

/// What typing into the numbers form stores (#279, #280).
///
/// Its own thing rather than an inline `Int(text)` at the call site, because a
/// failed parse must never reach a comparison as a value. A blank or unreadable
/// field comes out as "not counted", not as zero: zero is a real measurement,
/// and an account scored as having zero engagement sorts to the bottom of a
/// ranking as though it had been counted and found wanting.
enum AccountNumbersEntry {

    /// A typed figure, or nil when the field says nothing usable.
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Instagram shows "2,000" and that is what gets pasted in.
            .replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    /// What to put in the field for a stored figure.
    ///
    /// Round-trips with `parse`, so opening the form and saving it without
    /// touching a field cannot silently clear that field.
    static func text(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}

/// Remembers follower and engagement numbers per tagged handle, between events
/// (#279).
///
/// The collaborator ranking needs numbers to rank on, and the only source that
/// works without a platform API is Dan entering them. That is only worth doing
/// if the app keeps them: a performer tagged in March should already be scored
/// the next time they turn up, not asked for again.
///
/// File-backed rather than UserDefaults-backed because this is data Dan typed
/// by hand and cannot recover from anywhere else, so it needs the same
/// refuse-to-overwrite-what-we-could-not-read protection the event store has.
@MainActor
final class AccountBook {

    /// Why a load did or did not produce the real list.
    ///
    /// Two failures, not one (#505). They call for opposite handling, and
    /// collapsing them meant the recoverable one was treated as the
    /// unrecoverable one: a file that decoded as nonsense switched saving off
    /// for that session and every session after it, forever, because nothing
    /// ever moved the bad bytes out of the way. EventStore and AnalyticsStore
    /// have told the two apart since #88 and #439.
    enum LoadStatus: Equatable {
        /// Read, or genuinely not there yet (a first launch).
        case ok
        /// The bytes are there and are not account data. They are moved aside
        /// so saving can resume; `setAsideAs` is the name they were kept under,
        /// or nil when even that move failed, in which case saving stays off.
        case corrupt(setAsideAs: String?)
        /// The file could not be read at all (an I/O error, a failing volume).
        /// Its contents are unknown and untouched, and saving is refused:
        /// writing over them would destroy the numbers precisely because we
        /// could not read them.
        case unreadable
        /// The file is there and this process was refused it. Same consequence
        /// as `unreadable`, different cause and different sentence (#563): the
        /// numbers are intact behind a permissions problem, so there is nothing
        /// to restore and nothing to rebuild.
        case refused
    }

    /// Said out loud when the store could not be read.
    ///
    /// From every reader's point of view an unreadable book looks exactly like
    /// an empty one: every account comes back "not counted yet", the ranking
    /// goes entirely unranked, and nothing on screen distinguishes a file
    /// nobody has filled in from one that failed to load. An error state and an
    /// empty state are different screens.
    ///
    /// It names the file and the folder because the only fix is a file on disk,
    /// and a note that says "the file" identifies nothing to somebody standing
    /// in Finder (#505).
    nonisolated static func unreadableNote(file: String, folder: String) -> String {
        "Could not read the saved account numbers, so everything reads as not counted. "
        + "\(file) in \(folder) has been left alone rather than overwritten, and no new "
        + "numbers will be saved until it can be read."
    }

    /// The same situation, except PostRoll was refused the file rather than
    /// failing to make sense of it (#563).
    ///
    /// Distinct wording because the two need different things from Dan. A
    /// refusal means the numbers are sitting there intact behind a permissions
    /// problem on PostRoll's own storage, so there is nothing to restore and
    /// nothing to rebuild. Reported in the same words as an I/O error, it reads
    /// as a damaged file and sends him looking for a backup he does not need.
    ///
    /// No settings pane is named, for the reason #557 recorded: this file lives
    /// under Application Support, which System Settings does not list under
    /// Privacy & Security > Files and Folders, so naming that pane sends him to
    /// look for a switch that is not there (L111).
    nonisolated static func refusedNote(file: String, folder: String) -> String {
        "\(file) in \(folder) is still there and PostRoll was refused when it tried to "
        + "read it, so everything reads as not counted. Nothing in it was changed or "
        + "overwritten, and no new numbers will be saved until it can be read. This is a "
        + "permissions problem, not a damaged file."
    }

    /// The same situation, except the bytes were readable and turned out not to
    /// be account data. Distinct wording because the consequence is distinct:
    /// the numbers that were in there are gone, and new ones will be saved.
    nonisolated static func corruptNote(setAsideAs name: String?,
                                        file: String, folder: String) -> String {
        guard let name else {
            return "\(file) in \(folder) is not account data, and it could not be moved "
                 + "out of the way either, so everything reads as not counted and no new "
                 + "numbers will be saved over it."
        }
        return "\(file) in \(folder) is not account data, so everything reads as not "
             + "counted. Nothing was deleted: it was set aside as \(name), and new "
             + "numbers are being saved again."
    }

    /// What the caption and export surfaces should say, or nil when the book
    /// loaded properly.
    var recoveryNote: String? {
        let file = fileURL.lastPathComponent
        let folder = (fileURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
        switch loadStatus {
        case .ok: return nil
        case .unreadable: return Self.unreadableNote(file: file, folder: folder)
        case .refused: return Self.refusedNote(file: file, folder: folder)
        case .corrupt(let name):
            return Self.corruptNote(setAsideAs: name, file: file, folder: folder)
        }
    }

#if POSTROLL_TESTS
    /// The book the TEST BUNDLE gets: a disposable file, emptied once per run
    /// (#945).
    ///
    /// `init` calls `load()`, so the first touch of this property in a process
    /// reads whatever is at that path. Nothing redirected it, and nothing was
    /// wrong on the day only because no accounts.json existed yet. The file
    /// appears the first time an export records a follower count, and from
    /// then on every run of the suite would read real numbers about real
    /// people on a path nobody would think to check (L222).
    ///
    /// Compiled out of the shipping app, the way `AppPreferences.store` is, so
    /// the redirection is a property of the build rather than of each screen
    /// remembering to pass a book down (L2). The per-call seam stays:
    /// `AccountBook(fileURL:)` is how a test says which file it wants.
    static let shared = AccountBook(fileURL: scratchAccountsFile())

    /// A disposable accounts file, in a directory of its own that is emptied
    /// before the path is handed back.
    ///
    /// The whole DIRECTORY rather than the file, because `AccountBook` rotates
    /// a backup beside whatever it is given and sets a corrupt file aside
    /// there too, so clearing only the file would leave the rest of the run's
    /// leavings behind.
    ///
    /// Emptied on the same reasoning as the scratch preferences suite (#744):
    /// a fixed name means one run's writes are the next run's inputs unless
    /// something clears them, and that is diagnosed as a flaky test rather
    /// than as leftover state.
    ///
    /// A function rather than a `let` so a test can watch the clearing happen.
    /// Nothing inside a run can watch `shared` being built.
    static func scratchAccountsFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostRollTests-accounts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }
#else
    static let shared = AccountBook(fileURL: AppPaths.accountsFile)
#endif

    private let fileURL: URL
    private var records: [String: AccountRecord] = [:]
    private(set) var loadStatus: LoadStatus = .ok

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// The identity of an account: its bare username, case folded.
    ///
    /// Shares `CaptionBlocks.bareUsername` rather than restating it, so the
    /// spelling rules the tag list already applies are the same ones the book
    /// keys on. Two implementations would drift, and the drift would show up as
    /// one person quietly becoming two records.
    nonisolated static func key(_ raw: String) -> String {
        CaptionBlocks.bareUsername(raw).lowercased()
    }

    // MARK: - Reading

    /// Every account, newest tag first, then alphabetically.
    ///
    /// This ordering is what `lastTaggedOn` is FOR (#490). The comment on that
    /// field used to promise a browsable book with a screen behind it, which
    /// does not exist; what the stamp genuinely does is put the accounts Dan
    /// tagged most recently at the top of this list, and saying only that is
    /// what stops the field reading as wired to something it is not (L46).
    var all: [AccountRecord] {
        records.values.sorted {
            switch ($0.lastTaggedOn, $1.lastTaggedOn) {
            case let (a?, b?) where a != b: return a > b
            default: return $0.handle.lowercased() < $1.handle.lowercased()
            }
        }
    }

    /// What is known about one account, or nil if it has never been seen.
    ///
    /// Nil and "seen but uncounted" are deliberately different answers: the
    /// first means the app has nothing to show, the second means there is a
    /// record with no numbers in it, which is what a ranking has to render as
    /// unranked rather than scoring.
    func stats(for handle: String) -> AccountStats? {
        records[Self.key(handle)]?.stats
    }

    func record(for handle: String) -> AccountRecord? {
        records[Self.key(handle)]
    }

    /// Every account's figures, keyed for lookup off the main actor.
    ///
    /// The export runs detached, and this is main-actor state, so it is copied
    /// once rather than reached into from another thread.
    func snapshot() -> [String: AccountStats] {
        records.mapValues(\.stats)
    }

    // MARK: - Writing

    /// Enter or correct the figures for one account.
    ///
    /// A negative figure is refused rather than stored: it can only be a typo,
    /// and it would produce a negative engagement rate that sorts above every
    /// real account.
    func record(handle: String, followers: Int?, likes: Int?, comments: Int?,
                isPrivate: Bool? = nil, neverInvite: Bool? = nil,
                acceptedInvites: Int? = nil, declinedInvites: Int? = nil,
                on date: Date) {
        let key = Self.key(handle)
        guard !key.isEmpty else { return }
        var entry = records[key] ?? AccountRecord(handle: CaptionBlocks.bareUsername(handle))
        entry.handle = CaptionBlocks.bareUsername(handle)
        // A COPY, with the typed figures written over it (#1003). This used to
        // rebuild `AccountStats` from these four values, so typing a follower
        // count into the sheet erased the fetch outcome, the stable Instagram
        // id, the post mix and the private mark, and silently made that account
        // unrankable again (L510).
        //
        // The typed figures are written unconditionally, INCLUDING nil, because
        // clearing a field is a real action here: this is the one path where an
        // empty box means "I do not know this" rather than "I am not saying".
        //
        // A figure that comes back UNCHANGED keeps the provenance it had. The
        // sheet is pre-filled with what is stored, so it sends all three
        // figures back whether or not Dan touched them, and marking every one
        // of them typed would quietly downgrade a measured figure to a typed
        // one the first time he corrected a different field.
        let was = entry.stats
        var stats = was
        stats.followers = nonNegative(followers)
        stats.likes = nonNegative(likes)
        stats.comments = nonNegative(comments)
        stats.followersSource = Self.sourceAfterTyping(
            was: was.followers, now: stats.followers, previous: was.followersSource)
        stats.likesSource = Self.sourceAfterTyping(
            was: was.likes, now: stats.likes, previous: was.likesSource)
        stats.commentsSource = Self.sourceAfterTyping(
            was: was.comments, now: stats.comments, previous: was.commentsSource)
        stats.recordedOn = date
        // nil is not false (#982). The form states the mark on every save, but
        // every other caller is saving FIGURES and says nothing about privacy,
        // so an unstated mark is left exactly as it was rather than cleared to
        // the unmarked state a plain Bool default would write (L168).
        if let isPrivate { stats.isPrivate = isPrivate }
        if let neverInvite { stats.neverInvite = neverInvite }
        // Same rule as the marks (#986): the form states them, and a fetch or
        // any other writer says nothing, so an unstated count is left as it was
        // rather than reset to zero, which would put an account that always
        // refuses straight back at the top of the ranking.
        if let acceptedInvites { stats.acceptedInvites = max(0, acceptedInvites) }
        if let declinedInvites { stats.declinedInvites = max(0, declinedInvites) }
        entry.stats = stats
        records[key] = entry
        save()
    }

    /// What a figure's provenance becomes after a pass through the sheet.
    ///
    /// Cleared means nobody knows it, so it has no source. Unchanged means Dan
    /// did not touch it, so it keeps the one it had. Anything else he typed.
    private static func sourceAfterTyping(was: Int?, now: Int?,
                                          previous: AccountStats.FigureSource?)
        -> AccountStats.FigureSource? {
        guard now != nil else { return nil }
        return now == was ? (previous ?? .typed) : .typed
    }

    /// Store one account's figures outright, replacing whatever was there.
    ///
    /// For a caller that has a whole `AccountStats` and means it, which today
    /// is the tests and #982's private mark. Everything that arrives from a
    /// FETCH goes through `merge` instead, because a fetch speaks only about
    /// the figures it actually obtained.
    func write(_ stats: AccountStats, for handle: String) {
        let key = Self.key(handle)
        guard !key.isEmpty else { return }
        var entry = records[key] ?? AccountRecord(handle: CaptionBlocks.bareUsername(handle))
        entry.handle = CaptionBlocks.bareUsername(handle)
        entry.stats = stats
        records[key] = entry
        save()
    }

    /// Fold one fetch's result into what is already known (#1003).
    ///
    /// Refuses to merge across a CHANGED Instagram id. `business_discovery`
    /// looks up by a mutable display name, so a handle that changed hands
    /// returns a different account's audience under the same name, and merging
    /// it would attribute one account's figures to another with nothing
    /// anywhere reporting a problem. The refusal is recorded as an outcome
    /// rather than swallowed, because a merge that quietly did nothing is
    /// indistinguishable from one that had nothing to do (L11).
    func merge(_ incoming: AccountStats, for handle: String, on date: Date) {
        let key = Self.key(handle)
        guard !key.isEmpty else { return }
        var entry = records[key] ?? AccountRecord(handle: CaptionBlocks.bareUsername(handle))
        entry.handle = CaptionBlocks.bareUsername(handle)

        if let known = entry.stats.instagramID, let arriving = incoming.instagramID,
           known != arriving {
            var refused = entry.stats
            refused.outcome = .handleChangedHands
            entry.stats = refused
            records[key] = entry
            save()
            return
        }

        var merged = entry.stats.merged(with: incoming)
        if merged.recordedOn == nil { merged.recordedOn = date }
        entry.stats = merged
        records[key] = entry
        save()
    }

    /// Note that these accounts were tagged, without inventing numbers for them.
    ///
    /// Runs on every export, so it must never be a way to lose figures Dan
    /// typed in by hand: an existing record keeps its stats and only has its
    /// last-tagged date moved forward.
    func noteTagged(handles: [String], on date: Date) {
        var changed = false
        for handle in handles {
            let key = Self.key(handle)
            guard !key.isEmpty else { continue }
            var entry = records[key] ?? AccountRecord(handle: CaptionBlocks.bareUsername(handle))
            entry.lastTaggedOn = date
            records[key] = entry
            changed = true
        }
        if changed { save() }
    }

    private func nonNegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    // MARK: - Persistence

    private struct Wrapper: Codable {
        var records: [AccountRecord]

        init(records: [AccountRecord]) { self.records = records }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            records = try c.decodeIfPresent([AccountRecord].self, forKey: .records) ?? []
        }
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// True when `data` is a readable account book. The one predicate deciding
    /// both what is worth keeping as a backup and what a load will accept, so
    /// the backup ring cannot fill up with files this store would reject.
    private static func decodes(_ data: Data) -> Bool {
        (try? decoder().decode(Wrapper.self, from: data)) != nil
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Not there yet is a first launch, not a failure. Anything else is
            // a file we could not read, and the same refusal applies: we do not
            // know what is in it, so we must not write over it.
            // Through the shared classification rather than an inline copy of it
            // (#439): three stores were each deciding "is this file merely
            // absent" for themselves, and one of them had it wrong.
            if (error as NSError).isFileNotFound {
                StoreSaveGate.shared.unblock(fileURL)
            } else {
                NSLog("AccountBook: could not read \(fileURL.lastPathComponent): \(error)")
                StoreSaveGate.shared.block(fileURL)
                // Same refusal to write either way. Only the sentence differs,
                // because a refusal and a damaged file need different things
                // from Dan (#563).
                loadStatus = (error as NSError).isPermissionDenied ? .refused : .unreadable
            }
            return
        }
        do {
            let wrapper = try Self.decoder().decode(Wrapper.self, from: data)
            records = Dictionary(uniqueKeysWithValues:
                wrapper.records.filter { !Self.key($0.handle).isEmpty }
                    .map { (Self.key($0.handle), $0) })
            loadStatus = .ok
            StoreSaveGate.shared.unblock(fileURL)
        } catch {
            // The bytes are there and they are not account data. Move them out
            // of the way so saving can resume (#505): leaving them in place
            // switched saving off permanently, and these numbers are typed in
            // by hand and come from nowhere else, so silently never saving them
            // again is the expensive failure.
            NSLog("AccountBook: \(fileURL.lastPathComponent) is not account data: \(error)")
            let setAside = StoreRecovery.setAside(fileURL)
            if setAside == nil {
                // The original could not be preserved, so it is still the only
                // copy of whatever it held. Saving would erode it.
                StoreSaveGate.shared.block(fileURL)
            } else {
                StoreSaveGate.shared.unblock(fileURL)
            }
            loadStatus = .corrupt(setAsideAs: setAside?.lastPathComponent)
        }
    }

    private func save() {
        // The shared gate rather than `loadStatus == .ok` (#505). The two are
        // different questions: after a corrupt file has been set aside the load
        // did NOT produce the real list, and saving is nevertheless the right
        // thing to do, because the bytes it would have overwritten are now
        // safely under another name.
        guard !StoreSaveGate.shared.isBlocked(fileURL) else {
            NSLog("AccountBook: refusing to save over unreadable \(fileURL.lastPathComponent)")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Wrapper(records: all))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The same generations events.json and analytics.json have kept
            // since #102 and #88 (#440). This was the only hand-entered store
            // with no backup at all, and it is the one whose contents exist
            // nowhere else: one bad byte and every follower and engagement
            // figure Dan has typed was gone with nothing to fall back to.
            StoreBackups.rotate(store: fileURL, isValid: Self.decodes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("AccountBook: could not save \(fileURL.lastPathComponent): \(error)")
        }
    }
}
