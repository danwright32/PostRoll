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
        followers  = try c.decodeIfPresent(Int.self,  forKey: .followers)
        likes      = try c.decodeIfPresent(Int.self,  forKey: .likes)
        comments   = try c.decodeIfPresent(Int.self,  forKey: .comments)
        recordedOn = try c.decodeIfPresent(Date.self, forKey: .recordedOn)
    }

    init(followers: Int? = nil, likes: Int? = nil, comments: Int? = nil,
         recordedOn: Date? = nil) {
        self.followers = followers
        self.likes = likes
        self.comments = comments
        self.recordedOn = recordedOn
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

    /// What to show beside the numbers, wherever they are shown.
    ///
    /// Never a blank: a gap where a figure goes reads as a number that failed
    /// to load rather than one nobody has entered.
    func freshnessLabel(asOf now: Date) -> String {
        guard let recordedOn, hasEngagementData else { return "Not counted yet" }
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
    /// When this account was last tagged on an event. Makes the book browsable
    /// as "everyone ever tagged" rather than only "everyone ever counted".
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
        /// The file could not be read at all (a permission denial, an I/O
        /// error). Its contents are unknown and untouched, and saving is
        /// refused: writing over them would destroy the numbers precisely
        /// because we could not read them.
        case unreadable
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
        case .corrupt(let name):
            return Self.corruptNote(setAsideAs: name, file: file, folder: folder)
        }
    }

    static let shared = AccountBook(fileURL: AppPaths.accountsFile)

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
                on date: Date) {
        let key = Self.key(handle)
        guard !key.isEmpty else { return }
        var entry = records[key] ?? AccountRecord(handle: CaptionBlocks.bareUsername(handle))
        entry.handle = CaptionBlocks.bareUsername(handle)
        entry.stats = AccountStats(followers: nonNegative(followers),
                                   likes: nonNegative(likes),
                                   comments: nonNegative(comments),
                                   recordedOn: date)
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
                loadStatus = .unreadable
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
