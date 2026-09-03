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

    /// The engagement rate below which an account is demoted however large it
    /// is (#1005).
    ///
    /// 0.37%, the 10th percentile of the measured engagement rates in the
    /// account population committed in #1114. Not a chosen number: run
    /// `venv/bin/python -m postroll.ai.collaborator_metric` and it is printed
    /// from the data, so a population that moves shows up as a changed number
    /// rather than as a decision nobody revisits (L316).
    ///
    /// It demotes 7 of the 122, with only 4 within 20% of the line, so it is
    /// not cutting through a crowded region where a small move would carry
    /// several accounts across at once (L172).
    ///
    /// Why it has to exist: carnegiehall measured 433,555 followers, a 0.08%
    /// rate and 356 likes a post. On total interactions alone that is 8th of
    /// 78, which is the "large dead audience reaches nobody" case the design
    /// refuses. Without the floor it takes a slot off an account whose audience
    /// actually turns up.
    static let livelinessFloor = 0.0037

    /// The engagement rate assumed for an account Meta will not report on.
    ///
    /// 2.73%, the 25th percentile of the measured accounts in the 104 to 3,422
    /// follower band, which is the band those accounts fall in. Also computed
    /// from the committed population rather than chosen.
    ///
    /// Deliberately the 25th rather than the median: what is MEASURED about
    /// these accounts is that they are unmeasurable, so the number errs low
    /// rather than flattering an account nobody has counted. It is an
    /// assumption and is labelled as one wherever it renders.
    static let assumedRate = 0.0273

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
        ///
        /// Still here under the interactions metric because it is what the
        /// liveliness floor judges. It is no longer the score.
        let rate: Double?
        /// Whether that rate was ASSUMED rather than measured (#1005).
        ///
        /// Carried on the candidate rather than recomputed at each surface,
        /// because a rate bypassed at one site leaves the reason line claiming
        /// a measurement nobody took.
        let rateIsAssumed: Bool
        /// What to show beside the name. The figures used and whether the
        /// account is in the first photo, because an ordered list with no
        /// reasons is not something anyone can disagree with.
        let reason: String
    }

    /// What kind of answer this day has, which decides what every surface says
    /// about it (#964).
    ///
    /// The four are genuinely different answers and must never render alike.
    /// Before this existed the first two were both silence, so a day whose
    /// every tagged account should be invited looked exactly like a day nobody
    /// had considered (L11, L98).
    enum Coverage: Equatable {
        /// Nothing this post tags is an account that can be invited.
        case nothingTagged
        /// There are no more candidates than slots, so all of them go.
        /// Nobody was cut, so nothing here may read as a ranking.
        case allFit
        /// More candidates than slots, and no figures to choose between them
        /// (#1115).
        ///
        /// Not a ranking that happened to come back empty. That is what this
        /// day used to be: `.ranked` with an empty `suggested`, so both
        /// surfaces printed "Invite these:" and then named nobody. The
        /// condition is its own answer and says what would change it.
        ///
        /// It is the live case rather than an edge one. Measured 2026-08-31,
        /// the account book held nine records, six with a follower count and
        /// none with likes or comments, so every reel day on every real event
        /// took this path.
        case nothingToRank
        /// More candidates than slots, so this is an editorial decision and
        /// the list is ordered, with the fallbacks and the exclusion named.
        case ranked
    }

    struct Result: Equatable {
        /// Which of the three answers this is, and so what the surfaces say.
        var coverage: Coverage
        /// Everyone to invite. At most `maxPerPost`. Best first under
        /// `.ranked`; in the post's own tag order under `.allFit`, because an
        /// order nobody chose reads as a ranking that cut somebody.
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

    /// The collaborators to suggest for one post, always.
    ///
    /// Every posting day gets an answer (#964). Which of the three answers it
    /// is comes back on `coverage`, because "invite all four of these", "here
    /// are the five worth the slots" and "nobody is tagged yet" are different
    /// things to tell somebody and used to be the same silence.
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
                        notes: [String] = []) -> Result {
        // Deduplicated on the account book's key, so three spellings of one
        // person are one candidate rather than three slots.
        var seen = Set<String>()
        var keys: [String] = []
        for raw in handles {
            // A value that is not an account cannot be invited to collaborate,
            // so it is neither ranked NOR counted (#981). The count is what
            // decides whether this panel appears at all, so excluding junk from
            // the ranking alone would still raise a panel over a post with no
            // editorial decision to make.
            //
            // `isRealHandle` rather than either half of it spelled again: this
            // was the tenth surface reading a stored handle and the only one
            // not asking it. It subsumes the emptiness test that used to stand
            // here, because its own first guard is that same question asked of
            // the same normalized name.
            guard PythonBridge.isRealHandle(raw) else { continue }
            let key = AccountBook.key(raw)
            guard seen.insert(key).inserted else { continue }
            keys.append(key)
        }

        let firstPhotoKeys = firstPhoto.map { Set($0.map(AccountBook.key)) }
        let candidates = keys.map { key -> Candidate in
            let stats = stats(key)
            let inFirstPhoto = firstPhotoKeys?.contains(key) ?? false
            let scored = score(stats)
            return Candidate(handle: key, stats: stats, inFirstPhoto: inFirstPhoto,
                             rate: scored?.rate,
                             rateIsAssumed: scored?.assumed ?? false,
                             reason: reasonText(stats: stats, scored: scored,
                                                inFirstPhoto: inFirstPhoto,
                                                appliesFirstPhoto: firstPhotoKeys != nil,
                                                asOf: now))
        }

        // Nothing this post tags can be invited. Said out loud, because an
        // absent section reads as a day that was considered and needed no
        // invites, which is the opposite of what it means (#964).
        guard !candidates.isEmpty else {
            return Result(coverage: .nothingTagged, suggested: [], fallbacks: [],
                          strongestExcluded: nil, unranked: [], notes: notes)
        }

        // No more candidates than slots, so every one of them goes and there is
        // no editorial decision to report. In the post's own tag order rather
        // than a scored one: nobody was cut, and an order nobody chose reads as
        // a ranking that cut somebody.
        //
        // An account with no numbers is an invite here like any other. The
        // separate `unranked` list exists so an unmeasured account cannot take
        // a slot off a measured one; with no slot to lose there is nothing to
        // protect, and holding it back would be the same silence in a smaller
        // form.
        guard candidates.count > maxPerPost else {
            return Result(coverage: .allFit, suggested: candidates, fallbacks: [],
                          strongestExcluded: nil, unranked: [], notes: notes)
        }

        // Split by whether the account can be ranked at all, and carry the
        // values into the sort rather than the optionals. A rate or a follower
        // count coalesced to zero at the comparison would compare as a real
        // measurement, land on one side of the follower floor, and sort as
        // though the account had been counted and found wanting.
        let rankable = candidates.compactMap(Rankable.init)
        let unranked = candidates.filter { $0.rate == nil }

        // More candidates than slots and nothing to choose between them
        // (#1115). Returned as its own answer rather than as a ranking with an
        // empty result: "here are the five worth the slots" followed by nobody
        // is a promise the data cannot keep, and it is what every real event
        // produced.
        //
        // Every candidate is named as unranked, which is `candidates` itself
        // here: a rate cannot exist without a follower count above zero, so
        // nothing rankable means nothing with a rate.
        guard !rankable.isEmpty else {
            return Result(coverage: .nothingToRank, suggested: [], fallbacks: [],
                          strongestExcluded: nil, unranked: candidates, notes: notes)
        }

        let ranked = rankable.sorted { better($0, than: $1, respectingFirstPhoto: true) }
        let suggested = ranked.prefix(maxPerPost).map(\.candidate)

        // Only meaningful where a first-photo distinction exists. Without one
        // nothing is a fallback, because nothing fell through anything.
        let fallbacks = firstPhotoKeys == nil
            ? []
            : suggested.filter { !$0.inFirstPhoto }.map(\.handle)

        return Result(coverage: .ranked,
                      suggested: suggested,
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
        /// The score: total weighted interactions.
        let interactions: Double
        /// What the liveliness floor judges. Not the score.
        let rate: Double
        let followers: Int
        let isPrivate: Bool

        init?(_ candidate: Candidate) {
            guard let scored = score(candidate.stats),
                  let followers = candidate.stats?.followers, followers > 0
            else { return nil }
            self.candidate = candidate
            self.interactions = scored.interactions
            self.rate = scored.rate
            self.followers = followers
            self.isPrivate = candidate.stats?.isPrivate ?? false
        }

        /// Whether this account's audience is alive enough to be ranked on its
        /// size at all (#1005).
        var isLively: Bool { rate >= livelinessFloor }
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
                        notes: [String] = []) -> Result {
        let membership = firstPhotoHandles(event: event, day: day, preset: preset)
        return suggest(handles: CaptionBlocks.dayTagCandidates(event: event, day: day,
                                                               preset: preset),
                       firstPhoto: membership.handles.map(Set.init),
                       stats: stats, asOf: now, notes: notes + membership.notes)
    }

    // MARK: - The block in CAPTIONS.txt (#278)

    /// The section header, exactly as it appears in the file.
    static let captionHeader = "COLLABORATORS:"

    /// Said when a post tags nobody who could be invited.
    ///
    /// Printed rather than left out, so a day with nobody tagged yet is
    /// visibly different from a day this app never looked at (#964).
    static let nobodyTaggedLine =
        "Nobody on this day is tagged to an account yet, so there is nobody to invite."

    /// Said when every candidate fits inside the slots.
    ///
    /// Deliberately carries no ranking language: nobody was cut, and telling
    /// somebody a list is "the best five" when it is simply everyone invites a
    /// decision that does not exist.
    static func everyoneFitsLine(_ count: Int) -> String {
        guard count > 1 else {
            return "One account is tagged on this day and Instagram allows "
                 + "\(maxPerPost) collaborators per post, so invite them."
        }
        return "All \(count) accounts tagged on this day fit Instagram's "
             + "\(maxPerPost) collaborator slots, so invite every one of them."
    }

    /// Said of an account that can never be counted, however long anybody waits.
    ///
    /// Its own sentence rather than a share of the one above (#982). A private
    /// profile shows its follower count and nothing else: the per post figures
    /// the ranking needs are visible only to approved followers. Listed under
    /// "not counted yet" it read as an outstanding job, printed again every
    /// week, with no action anywhere that could ever clear it (L11).
    static let privateLine =
        "Private, so an invite reaches only their own approved followers: "

    /// What the mark MEANS, said beside the control that makes it (#982).
    ///
    /// Worded here with the rest of them rather than in the view, so the
    /// sentence Dan reads while ticking the box and the sentence CAPTIONS.txt
    /// prints afterwards cannot come to describe the same mark differently.
    static let privateFormNote =
        "Their posts cannot be counted, and an invite reaches only their own "
        + "approved followers, so they are ranked last rather than asked for "
        + "numbers."

    /// The unranked list split into the two different things it holds.
    ///
    /// Named rather than counted in both halves, so it is visible WHO is in
    /// which state and the remedy, where there is one, can be acted on without
    /// opening the app.
    private static func unrankedLines(_ unranked: [Candidate]) -> [String] {
        let marked = unranked.filter { $0.stats?.isPrivate == true }
        let waiting = unranked.filter { $0.stats?.isPrivate != true }
        var lines: [String] = []
        if !waiting.isEmpty {
            lines.append("Not counted yet, so not ranked: "
                         + waiting.map(\.handle).joined(separator: ", "))
        }
        if !marked.isEmpty {
            lines.append(privateLine + marked.map(\.handle).joined(separator: ", "))
        }
        return lines
    }

    /// Said when there are more candidates than slots and none of them has any
    /// figures at all (#1115).
    ///
    /// Names the condition and the way out, in the shape the other three use.
    /// The count is always above `maxPerPost` by the time this is reached, so
    /// there is no singular form to write.
    static func nothingToRankLine(_ count: Int) -> String {
        "\(count) accounts are tagged and Instagram allows \(maxPerPost) "
        + "collaborators per post, but none of them has any numbers yet, so "
        + "there is nothing to rank. Add numbers and this will name \(maxPerPost)."
    }

    /// The sentence the review screen puts under its heading, for any answer.
    ///
    /// Here rather than in the view so the screen and CAPTIONS.txt cannot come
    /// to describe the same day differently. Two of the four already read from
    /// this file and two were typed into the view, which is the drift this
    /// closes; `CollaboratorPickTests` holds the view to it.
    static func panelSubtitle(for result: Result) -> String {
        switch result.coverage {
        case .nothingTagged:
            return nobodyTaggedLine
        case .allFit:
            return everyoneFitsLine(result.suggested.count)
                 + " A collaborator invite puts this post on their own grid."
        case .nothingToRank:
            return nothingToRankLine(result.unranked.count)
        case .ranked:
            return "Instagram allows \(maxPerPost) per post. "
                 + "A collaborator invite puts this post on their own grid."
        }
    }

    /// One day's collaborator section.
    ///
    /// Built from the same `Result` the review screen renders, so the names in
    /// the file and the names on screen cannot disagree. Everything that was
    /// decided is stated: who to invite and why, who filled a slot that fell
    /// through, who was left out only by the first-photo rule, and who has no
    /// numbers at all. An account silently dropped looks like one that was
    /// considered and rejected.
    ///
    /// Four shapes, one per `Coverage`, because the four are different
    /// answers (#964, #1115). Under `.allFit` the names carry no position numbers:
    /// a numbered list is a ranking however the sentence above it is worded.
    static func captionBlock(_ result: Result) -> String {
        var lines = [captionHeader]
        switch result.coverage {
        case .nothingTagged:
            lines.append(nobodyTaggedLine)
        case .allFit:
            lines.append(everyoneFitsLine(result.suggested.count))
            for candidate in result.suggested {
                lines.append("\(candidate.handle) (\(candidate.reason))")
            }
        case .nothingToRank:
            lines.append(nothingToRankLine(result.unranked.count))
            lines.append(contentsOf: unrankedLines(result.unranked))
        case .ranked:
            lines.append("Instagram allows \(maxPerPost) collaborators per post. Invite these:")
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
            lines.append(contentsOf: unrankedLines(result.unranked))
        }
        lines.append(contentsOf: result.notes)
        return lines.joined(separator: "\n")
    }

    // MARK: - Scoring

    /// What one account scores, and whether any of it was assumed (#1005).
    ///
    /// `interactions` is the score: `likes + 3 * comments`, which is what
    /// actually lands on a post. Deliberately not written as "followers times
    /// the engagement rate", which is the SAME expression with the followers
    /// cancelling, and which reads as if it combined two signals.
    ///
    /// `rate` is not the score. It is what the liveliness floor judges, and it
    /// is the only thing followers are needed for.
    struct Score: Equatable {
        let interactions: Double
        let rate: Double
        /// True when the rate, and therefore the interactions derived from it,
        /// are an assumption rather than a measurement.
        let assumed: Bool
        /// True when the assumption exists because the ACCOUNT withheld its
        /// like count, rather than because Meta would not report on it at all
        /// (#1032). Two causes with two remedies, so two messages (L11): an
        /// account that hides a figure may start showing it, and one Meta
        /// cannot report on never will.
        var likesHidden: Bool = false
    }

    /// One account's score, or nil when there is nothing to score it on.
    ///
    /// Two ways in, and the second is narrow on purpose. A measured account is
    /// scored on its own figures. An account Meta REFUSED to report on, which
    /// is a fact about the account rather than an absence of effort, is scored
    /// on the assumed rate against the follower count the profile page gave
    /// (#1006). An account nobody has looked at is scored on neither: the
    /// decision that an unmeasured account is never scored was narrowed here,
    /// not reversed.
    static func score(_ stats: AccountStats?) -> Score? {
        // A private account IS scored (#982). Demote, do not exclude: `better`
        // ranks it below every public candidate, which leaves it able to fill a
        // slot no public account can fill, and an unscored account would fall
        // out of the ranking into the list of accounts waiting on numbers it
        // already has.
        guard let stats else { return nil }
        guard let followers = stats.followers, followers > 0 else { return nil }

        // A withheld like count is handled BEFORE the measured path, because
        // the account does have engagement data by any ordinary reading of the
        // word: it answered, and it kept one figure back (#1032). Scored on the
        // assumption rather than on the figures it did give, for the reason
        // recorded on `assumedRate`.
        if stats.likesAreHidden {
            return Score(interactions: Double(followers) * assumedRate,
                         rate: assumedRate, assumed: true, likesHidden: true)
        }

        if stats.hasEngagementData {
            // These two defaults are additive terms in a sum, not values
            // reaching a comparison: a half nobody counted contributes none of
            // that half. The account is known to have at least one of them, the
            // bias is downward rather than up, so partial data can never
            // promote an account over a fully counted one, and the reason line
            // names exactly which figures were used.
            let interactions = Double(stats.likes ?? 0)
                             + Double(stats.comments ?? 0) * Double(commentWeight)
            return Score(interactions: interactions,
                         rate: interactions / Double(followers),
                         assumed: false)
        }

        // Only a refusal Meta actually made. `couldNotClassify` is NOT enough:
        // it means nothing established what this account is, and assuming a
        // rate on the strength of a failure would score an account on a
        // measurement nobody took (L67).
        guard stats.outcome == .notProfessional || stats.outcome == .noSuchAccount
        else { return nil }
        return Score(interactions: Double(followers) * assumedRate,
                     rate: assumedRate,
                     assumed: true)
    }

    /// Interactions per follower, comments weighted, or nil when unrankable.
    ///
    /// Kept because several surfaces ask this question directly. It is the
    /// floor's input, not the ranking's score.
    static func engagementRate(_ stats: AccountStats?) -> Double? {
        score(stats).map(\.rate)
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
        // Private is the OUTERMOST key (#982). An invite to a private account
        // cannot put the post on a grid anybody can see, so the slot is wasted
        // however good the figures are.
        if a.isPrivate != b.isPrivate { return !a.isPrivate }
        if respectingFirstPhoto, a.candidate.inFirstPhoto != b.candidate.inFirstPhoto {
            return a.candidate.inFirstPhoto
        }
        // The liveliness floor, as an outer key over the score rather than a
        // tiebreak (#1005). A large audience that nothing engages with beats
        // every ordinary account on raw interactions, and reaches nobody.
        if a.isLively != b.isLively { return a.isLively }
        if a.interactions != b.interactions { return a.interactions > b.interactions }
        if a.followers != b.followers { return a.followers > b.followers }
        return a.candidate.handle < b.candidate.handle
    }

    // MARK: - Saying why

    /// Said when the API refused to report on an account and the score is
    /// therefore an assumption (#1005).
    static let assumedRateLabel =
        "no engagement figures, so scored on an assumed \(percentText(assumedRate)) rate"

    /// Said when the ACCOUNT withheld its like count (#1032).
    ///
    /// Distinct from the label above because the causes have different
    /// remedies: an account that hides a figure may start showing it, and one
    /// Meta cannot report on never will.
    static let hiddenLikesLabel =
        "like count hidden by the account, so scored on an assumed "
        + "\(percentText(assumedRate)) rate"

    /// Said when an account is demoted for having an audience that is not there.
    static let belowFloorLabel = "audience barely engages, so it is ranked last"

    private static func reasonText(stats: AccountStats?, scored: Score?,
                                   inFirstPhoto: Bool,
                                   appliesFirstPhoto: Bool, asOf now: Date) -> String {
        var parts: [String] = []
        if let stats, let scored, let followers = stats.followers {
            parts.append("\(number(followers)) followers")
            if scored.assumed {
                // Labelled wherever it renders. What is measured about this
                // account is that it is unmeasurable, and a reason line that
                // reported the assumed figures as measurements would claim
                // something nobody took.
                parts.append(scored.likesHidden ? hiddenLikesLabel : assumedRateLabel)
                // The comments ARE measured even when the likes are not, so
                // they are still named: dropping them would understate what is
                // actually known about the account.
                if scored.likesHidden, let comments = stats.comments {
                    parts.append("\(number(comments)) comments measured")
                }
            } else {
                if let likes = stats.likes { parts.append("\(number(likes)) likes") }
                if let comments = stats.comments { parts.append("\(number(comments)) comments") }
            }
            // The SCORE itself, so the order can be disagreed with. This used
            // to render "X% engagement", which described a metric that no
            // longer exists.
            parts.append("\(number(Int(scored.interactions.rounded()))) interactions a post")
            if scored.rate < livelinessFloor {
                parts.append("\(percent(scored.rate)) engagement, \(belowFloorLabel)")
            }
        } else {
            // Never a zero: an unmeasured account said to have 0% engagement is
            // a claim the app has no basis for.
            //
            // Which of the two unranked states this is, though (#977). "Not
            // counted yet" meant both "nobody has opened this" and "this has a
            // follower count and needs one more figure", and those need
            // different things done to them. The label comes from the record
            // rather than being spelled again here, so the suggestion line and
            // the panel row cannot describe one account differently.
            // Three unranked states now, not two (#982). A private account is
            // not waiting on anything, so it must not read like an account that
            // is.
            switch stats?.countedness {
            case .followersOnly, .privateAccount:
                parts.append(stats?.freshnessLabel(asOf: now) ?? "Not counted yet")
            default:
                parts.append("Not counted yet")
            }
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

    private static func percent(_ rate: Double) -> String { percentText(rate) }

    /// One rendering of a rate, so the label above and the reason line below
    /// cannot come to spell the same number differently.
    static func percentText(_ rate: Double) -> String {
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
