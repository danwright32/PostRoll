import Foundation

/// Which of a post's tagged accounts to invite as Instagram collaborators
/// (#278).
///
/// A tag puts someone in the "tagged people" list, which almost nobody sees. A
/// collaborator invite puts the post on that account's own grid and in front of
/// their followers, so it is the single biggest reach lever in the week's
/// output. Instagram allows 20 tags and 5 collaborators per post, so the moment
/// a post carries more than 5 tags there are more candidates than slots, and
/// the choice of who gets one is a real editorial decision that was being made
/// by eye, or not at all.
///
/// One implementation, used by both the review screen and the export, so the
/// names Dan reads are the names the file tells him to invite.
enum CollaboratorPick {

    /// How many accounts Instagram will let collaborate on one post.
    ///
    /// 5, confirmed by Dan on 2026-08-10, alongside the 20 tag limit in
    /// `CaptionBlocks.maxTagsPerPost`. Named with that date rather than typed
    /// inline at each use, because Instagram has changed limits of this kind
    /// before and a number nobody can find the provenance of gets copied
    /// forward long after it stopped being true.
    static let maxPerPost = 5

    /// How much more a comment is worth than a like when scoring an audience.
    ///
    /// A comment takes real effort, so it is a stronger signal that an audience
    /// is alive and being shown the posts. The exact weight rarely decides
    /// anything (in Dan's own example the live account wins by fortyfold at any
    /// weight); it only separates two accounts with similar interaction totals.
    static let commentWeight = 3

    /// Below this, an engagement rate comes from too few interactions to mean
    /// anything: 5 likes on 20 followers is a 25% rate off almost no data.
    /// Accounts under the floor still rank, but always below accounts over it,
    /// so a handful of interactions cannot top the list.
    static let followerFloor = 200

    /// Said out loud when first-photo membership could not be established.
    ///
    /// Getting this silently wrong does not fail loudly: it credits the wrong
    /// person and the suggestion looks entirely reasonable, so the alternative
    /// to naming it is a confident wrong answer.
    static let firstPhotoUnresolvedNote =
        "Could not tell who is in the first photo, so these are ranked on engagement alone."

    // MARK: - Shapes

    struct Candidate: Equatable {
        let handle: String
        let stats: AccountStats?
        let inFirstPhoto: Bool
        /// Interactions per follower, comments weighted. Nil when the account
        /// has no numbers: an unmeasured account must never be scored as zero,
        /// which would sort it to the bottom as though it had been measured and
        /// found wanting.
        let rate: Double?
        /// What to show beside the name. The figures used and whether the
        /// account is in the first photo, because an ordered list with no
        /// reasons is not something anyone can disagree with.
        let reason: String
    }

    struct Result: Equatable {
        /// At most `maxPerPost`, best first.
        var suggested: [Candidate]
        /// Which of the suggested are NOT in the first photo, in order. Empty
        /// when no first-photo distinction applies. Named so Dan can see the
        /// difference between a first-photo pick and a slot that fell through
        /// to whoever was strongest elsewhere.
        var fallbacks: [String]
        /// The strongest account excluded PURELY for not being in the first
        /// photo, so it can be swapped in by hand when the trade is obviously
        /// worth it. Nil when nothing was excluded by that rule alone.
        var strongestExcluded: Candidate?
        /// Tagged accounts with no numbers yet. Listed, never scored.
        var unranked: [Candidate]
        var notes: [String]
    }

    // MARK: - The pick

    /// The collaborators to suggest, or nil when there is no choice to make.
    ///
    /// - Parameters:
    ///   - handles: every account this post tags, in the order the post lists
    ///     them. Deduplicated here on the same key the account book uses.
    ///   - firstPhoto: who appears in the first photo of the carousel, or nil
    ///     when the post has no first-photo distinction (a single image, a
    ///     reel, or a first photo that could not be resolved). An EMPTY set is
    ///     a different answer from nil: it means the first photo genuinely tags
    ///     nobody, so everyone is a fallback.
    ///   - stats: what is known about one account. Passed as a lookup rather
    ///     than the book itself, so this stays a pure function.
    static func suggest(handles: [String], firstPhoto: Set<String>?,
                        stats: (String) -> AccountStats?, asOf now: Date,
                        notes: [String] = []) -> Result? {
        // Deduplicated on the account book's key, so three spellings of one
        // person are one candidate rather than three slots.
        var seen = Set<String>()
        var keys: [String] = []
        for raw in handles {
            let key = AccountBook.key(raw)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            keys.append(key)
        }

        // Fewer than six tags means there are no more candidates than slots, so
        // there is no editorial decision to make and nothing worth showing.
        guard keys.count > maxPerPost else { return nil }

        let firstPhotoKeys = firstPhoto.map { Set($0.map(AccountBook.key)) }
        let candidates = keys.map { key -> Candidate in
            let stats = stats(key)
            let inFirstPhoto = firstPhotoKeys?.contains(key) ?? false
            return Candidate(handle: key, stats: stats, inFirstPhoto: inFirstPhoto,
                             rate: engagementRate(stats),
                             reason: reasonText(stats: stats, inFirstPhoto: inFirstPhoto,
                                                appliesFirstPhoto: firstPhotoKeys != nil,
                                                asOf: now))
        }

        // Split by whether the account can be ranked at all, and carry the
        // values into the sort rather than the optionals. A rate or a follower
        // count coalesced to zero at the comparison would compare as a real
        // measurement, land on one side of the follower floor, and sort as
        // though the account had been counted and found wanting.
        let rankable = candidates.compactMap(Rankable.init)
        let unranked = candidates.filter { $0.rate == nil }

        let ranked = rankable.sorted { better($0, than: $1, respectingFirstPhoto: true) }
        let suggested = ranked.prefix(maxPerPost).map(\.candidate)

        // Only meaningful where a first-photo distinction exists. Without one
        // nothing is a fallback, because nothing fell through anything.
        let fallbacks = firstPhotoKeys == nil
            ? []
            : suggested.filter { !$0.inFirstPhoto }.map(\.handle)

        return Result(suggested: suggested,
                      fallbacks: fallbacks,
                      strongestExcluded: excludedPurelyByFirstPhotoRule(
                        ranked: ranked, suggested: suggested, applies: firstPhotoKeys != nil),
                      unranked: unranked,
                      notes: notes)
    }

    /// The account that would have made the five on engagement alone, and did
    /// not only because it is not in the first photo.
    ///
    /// Deliberately not "the best account that missed out": an account that
    /// would have missed the cut anyway must not be offered as a swap, or the
    /// line stops meaning anything and becomes noise on every post.
    private static func excludedPurelyByFirstPhotoRule(
        ranked: [Rankable], suggested: [Candidate], applies: Bool) -> Candidate? {
        guard applies else { return nil }
        let suggestedHandles = Set(suggested.map(\.handle))
        let onMeritAlone = ranked
            .sorted { better($0, than: $1, respectingFirstPhoto: false) }
            .prefix(maxPerPost)
        return onMeritAlone.first {
            !$0.candidate.inFirstPhoto && !suggestedHandles.contains($0.candidate.handle)
        }?.candidate
    }

    /// A candidate that can actually be ranked: its rate and follower count are
    /// values, not optionals waiting to be defaulted at a comparison.
    ///
    /// The type is the guard. An unmeasured account cannot be constructed here,
    /// so it cannot reach the sort, so there is no place left for a `?? 0` to
    /// turn "nobody counted this" into "this scored zero".
    private struct Rankable {
        let candidate: Candidate
        let rate: Double
        let followers: Int

        init?(_ candidate: Candidate) {
            guard let rate = candidate.rate,
                  let followers = candidate.stats?.followers, followers > 0
            else { return nil }
            self.candidate = candidate
            self.rate = rate
            self.followers = followers
        }
    }

    // MARK: - Reading one day of the event

    /// Who is in the photo that appears in the feed, and anything that has to
    /// be said about how confidently that was established.
    struct FirstPhotoMembership: Equatable {
        /// The handles, or nil when no first-photo distinction applies: a reel,
        /// a single-image day, a day with no photos, or a day whose tag data no
        /// longer describes its photos.
        var handles: [String]?
        var notes: [String]
    }

    /// The people in the first carousel item.
    ///
    /// The first carousel item is `photoPaths[0]`, one photo. It is NOT the
    /// collage: on a collage carousel day the collage doubles as the STORY
    /// (`generate_media`: "a 4 photo carousel whose collage doubles as the
    /// story"), and `EventExporter` copies the assigned photos into
    /// `carousel/` as 01..N. So there is no collage layout to read here, and
    /// none of the index-into-the-photo-list identity that sidecar records.
    ///
    /// Membership is resolved by filename through `CaptionBlocks.photoTags`,
    /// and refused outright when the day's tag data names a photo set the day
    /// no longer has. Refused rather than read: guessing here does not fail
    /// loudly, it credits the wrong person while looking entirely reasonable.
    static func firstPhotoHandles(event: Event, day: DayName,
                                  preset: PostingPreset) -> FirstPhotoMembership {
        // A reel or a single-image post has no first photo to be in.
        guard preset.isCollageCarousel(day),
              let posting = event.days[day.rawValue],
              let first = posting.photoPaths.first
        else { return FirstPhotoMembership(handles: nil, notes: []) }

        let handles = CaptionBlocks.photoTags(posting, for: first)
            .map(CaptionBlocks.bareUsername)
            .filter { !$0.isEmpty }
        guard handles.isEmpty else { return FirstPhotoMembership(handles: handles, notes: []) }

        // The first photo has no tags of its own. That is a real answer when
        // the day's tag data all lines up with its photos: nobody is in it.
        //
        // It is NOT a real answer when tags exist against photos the day no
        // longer has, because the first photo's people could be sitting in
        // those orphans. The two look identical from here, so the ambiguity is
        // named rather than resolved in favour of the convenient reading.
        let currentNames = Set(posting.photoPaths.map(\.lastPathComponent))
        let hasOrphanedTags = posting.photoTags.contains { key, tags in
            guard !tags.isEmpty else { return false }
            guard let name = URL(string: key)?.lastPathComponent else { return true }
            return !currentNames.contains(name)
        }
        return hasOrphanedTags
            ? FirstPhotoMembership(handles: nil, notes: [firstPhotoUnresolvedNote])
            : FirstPhotoMembership(handles: [], notes: [])
    }

    /// The suggestion for one day of one event.
    ///
    /// The entry point both the review screen and the export use, so the names
    /// Dan reads on screen are the names the file tells him to invite.
    /// - Parameter notes: anything the caller knows that the figures cannot
    ///   show, such as the account book having failed to load, which otherwise
    ///   reads identically to nobody having entered any numbers.
    static func suggest(event: Event, day: DayName, preset: PostingPreset,
                        stats: (String) -> AccountStats?, asOf now: Date,
                        notes: [String] = []) -> Result? {
        let membership = firstPhotoHandles(event: event, day: day, preset: preset)
        return suggest(handles: CaptionBlocks.dayTagCandidates(event: event, day: day,
                                                               preset: preset),
                       firstPhoto: membership.handles.map(Set.init),
                       stats: stats, asOf: now, notes: notes + membership.notes)
    }

    // MARK: - The block in CAPTIONS.txt (#278)

    /// The section header, exactly as it appears in the file.
    static let captionHeader = "COLLABORATORS:"

    /// One day's collaborator section.
    ///
    /// Built from the same `Result` the review screen renders, so the names in
    /// the file and the names on screen cannot disagree. Everything that was
    /// decided is stated: who to invite and why, who filled a slot that fell
    /// through, who was left out only by the first-photo rule, and who has no
    /// numbers at all. An account silently dropped looks like one that was
    /// considered and rejected.
    static func captionBlock(_ result: Result) -> String {
        var lines = [captionHeader,
                     "Instagram allows \(maxPerPost) collaborators per post. Invite these:"]
        for (index, candidate) in result.suggested.enumerated() {
            lines.append("\(index + 1). \(candidate.handle) (\(candidate.reason))")
        }
        if !result.fallbacks.isEmpty {
            lines.append("Filling the remaining slots, not in the first photo: "
                         + result.fallbacks.joined(separator: ", "))
        }
        if let excluded = result.strongestExcluded {
            lines.append("Left out only for not being in the first photo, "
                         + "swap in by hand if the reach is worth it: "
                         + "\(excluded.handle) (\(excluded.reason))")
        }
        if !result.unranked.isEmpty {
            lines.append("Not counted yet, so not ranked: "
                         + result.unranked.map(\.handle).joined(separator: ", "))
        }
        lines.append(contentsOf: result.notes)
        return lines.joined(separator: "\n")
    }

    // MARK: - Scoring

    /// Interactions per follower, comments weighted, or nil when unrankable.
    ///
    /// Nil rather than zero for a missing or zero follower count: a rate is
    /// interactions over followers, so zero followers cannot produce one, and
    /// must not produce an infinity that sorts first.
    static func engagementRate(_ stats: AccountStats?) -> Double? {
        guard let stats, stats.hasEngagementData, let followers = stats.followers,
              followers > 0 else { return nil }
        // These two defaults are additive terms in a sum, not values reaching a
        // comparison: a half nobody counted contributes none of that half. The
        // account is already known to have at least one of them
        // (`hasEngagementData`), the bias is downward rather than up, so partial
        // data can never promote an account over a fully counted one, and the
        // reason line names exactly which figures were used, so the score never
        // claims more than was measured.
        let interactions = Double(stats.likes ?? 0) + Double(stats.comments ?? 0) * Double(commentWeight)
        return interactions / Double(followers)
    }

    /// The whole ranking, in one place.
    ///
    /// Being in the first photo comes first and is a hard bias rather than a
    /// tiebreak: on a carousel only the first photo appears in the feed, so
    /// someone who is not in it is being asked to put a post on their own grid
    /// whose visible image does not show them, and they will usually decline.
    /// A declined invite is a wasted slot out of five.
    ///
    /// Then the follower floor, then the engagement rate, then followers, then
    /// the handle. The last one is not cosmetic: without a total order the five
    /// names reshuffle every time the panel redraws, and a suggestion that
    /// changes with no input changing cannot be trusted.
    private static func better(_ a: Rankable, than b: Rankable,
                               respectingFirstPhoto: Bool) -> Bool {
        if respectingFirstPhoto, a.candidate.inFirstPhoto != b.candidate.inFirstPhoto {
            return a.candidate.inFirstPhoto
        }
        let aOverFloor = a.followers >= followerFloor
        let bOverFloor = b.followers >= followerFloor
        if aOverFloor != bOverFloor { return aOverFloor }
        if a.rate != b.rate { return a.rate > b.rate }
        if a.followers != b.followers { return a.followers > b.followers }
        return a.candidate.handle < b.candidate.handle
    }

    // MARK: - Saying why

    private static func reasonText(stats: AccountStats?, inFirstPhoto: Bool,
                                   appliesFirstPhoto: Bool, asOf now: Date) -> String {
        var parts: [String] = []
        if let stats, stats.hasEngagementData, let followers = stats.followers,
           let rate = engagementRate(stats) {
            parts.append("\(number(followers)) followers")
            if let likes = stats.likes { parts.append("\(number(likes)) likes") }
            if let comments = stats.comments { parts.append("\(number(comments)) comments") }
            parts.append("\(percent(rate)) engagement")
            if followers < followerFloor {
                parts.append("small audience, so the rate is off few interactions")
            }
        } else {
            // Never a zero: an unmeasured account said to have 0% engagement is
            // a claim the app has no basis for.
            parts.append("Not counted yet")
        }
        if appliesFirstPhoto {
            parts.append(inFirstPhoto ? "in the first photo" : "not in the first photo")
        }
        if let stats, stats.freshness(asOf: now).isStale {
            parts.append(stats.freshnessLabel(asOf: now).lowercased())
        }
        return parts.joined(separator: ", ")
    }

    private static func number(_ value: Int) -> String {
        Self.grouping.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func percent(_ rate: Double) -> String {
        String(format: "%.1f%%", rate * 100)
    }

    nonisolated(unsafe) private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        // Set explicitly rather than left to the style: en_US_POSIX does not
        // group by default, so a follower count read as "10000" beside one read
        // as "2,000" would be a formatting difference that looks like a data
        // difference.
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        return f
    }()
}
