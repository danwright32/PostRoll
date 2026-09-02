import XCTest

/// #278: when a post carries more than 5 tags, say which of those accounts to
/// invite as collaborators.
///
/// A tag puts someone in the "tagged people" list, which almost nobody sees. A
/// collaborator invite puts the post on that account's own grid and in front of
/// their followers, so it is the single biggest reach lever in the week's
/// output. Instagram allows 20 tags and 5 collaborators per post, so the moment
/// a post carries more than 5 tags there are more candidates than slots.
///
/// Two rules decide the five. Engagement quality, not raw follower count, and
/// being in the first photo of a carousel, which is a hard bias rather than a
/// tiebreak: on a carousel only the first photo appears in the feed, so someone
/// who is not in it is being asked to put a post on their own grid whose
/// visible image does not show them, and they will usually decline. A declined
/// invite is a wasted slot out of five.
final class CollaboratorPickTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    /// A stats lookup built from a dictionary, so these tests never touch a
    /// file or the shared book.
    private func lookup(_ table: [String: AccountStats]) -> (String) -> AccountStats? {
        { handle in table[AccountBook.key(handle)] }
    }

    private func stats(_ followers: Int, _ likes: Int, _ comments: Int,
                       ageDays: Int = 0) -> AccountStats {
        AccountStats(followers: followers, likes: likes, comments: comments,
                     recordedOn: now.addingTimeInterval(-Double(ageDays) * 86_400))
    }

    // MARK: - Every posting day carries a block (#964)

    /// The old rule refused outright at five or fewer candidates, so the days
    /// carrying the best photos said nothing at all. A silent block is
    /// indistinguishable from a post that was considered and found to need no
    /// invites (L11), and the reach a tag does not buy is the whole point.

    func testEveryCandidateIsNamedWhenTheyAllFitTheSlots() {
        // Five candidates for five slots is the clearest case there is: invite
        // all of them. Nobody was cut, so nothing may read as a ranking.
        let handles = ["a", "b", "c", "d", "e"]
        let table = Dictionary(uniqueKeysWithValues: handles.map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        XCTAssertEqual(result.coverage, .allFit)
        XCTAssertEqual(Set(result.suggested.map(\.handle)), Set(handles))
        XCTAssertTrue(result.fallbacks.isEmpty, "nothing fell through, nothing was cut")
        XCTAssertNil(result.strongestExcluded)
    }

    func testADayThatTagsNobodySaysSoRatherThanPrintingNothing() {
        // "Nobody is tagged yet" and "this day was not considered" are
        // different answers and must not look the same (L98).
        let result = CollaboratorPick.suggest(handles: [], firstPhoto: nil,
                                              stats: lookup([:]), asOf: now)
        XCTAssertEqual(result.coverage, .nothingTagged)
        XCTAssertTrue(result.suggested.isEmpty)
        XCTAssertTrue(result.unranked.isEmpty)
    }

    func testAnUncountedAccountIsStillOneOfTheInvitesWhenTheyAllFit() {
        // In ranking mode an unmeasured account must not take a slot off a
        // measured one, so it is listed apart. With no slot to lose there is
        // nothing to protect, and leaving it out of the invite list would be
        // the same silence in a smaller form.
        let handles = ["a", "b", "nonumbers"]
        let result = CollaboratorPick.suggest(
            handles: handles, firstPhoto: nil,
            stats: lookup(["a": stats(1_000, 50, 5), "b": stats(1_000, 40, 5)]), asOf: now)
        XCTAssertEqual(result.coverage, .allFit)
        XCTAssertTrue(result.suggested.map(\.handle).contains("nonumbers"))
        XCTAssertTrue(result.unranked.isEmpty, "named once as an invite, not twice")
    }

    func testSixTagsStillRankAndStillCutToFive() {
        let handles = ["a", "b", "c", "d", "e", "f"]
        let table = Dictionary(uniqueKeysWithValues: handles.map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        XCTAssertEqual(result.coverage, .ranked)
        XCTAssertEqual(result.suggested.count, 5, "never more than Instagram allows")
    }

    func testTheModeCountsTagsIncludingOnesWithNoNumbers() {
        // Six tags is six tags. Counting only the rankable ones would flip the
        // day between naming everyone and ranking as numbers are entered.
        let handles = ["a", "b", "c", "d", "e", "f"]
        let table = ["a": stats(1_000, 50, 5)]
        XCTAssertEqual(CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                                stats: lookup(table), asOf: now).coverage,
                       .ranked)
    }

    func testDuplicateSpellingsAreOnePersonAndDoNotInflateTheCount() {
        // Six spellings of five people is five candidates, so they all fit.
        let handles = ["@jane", "jane", "https://instagram.com/JANE/", "b", "c", "d", "e"]
        let table = Dictionary(uniqueKeysWithValues:
            ["jane", "b", "c", "d", "e"].map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        XCTAssertEqual(result.coverage, .allFit)
        XCTAssertEqual(result.suggested.count, 5)
    }

    // MARK: - A value that is not an account is not a candidate (#981)

    /// `unknown` is the sentinel `caption_blocks` records when a lookup found
    /// nobody, and it is perfectly well shaped, so only the sentinel half of
    /// `isRealHandle` rejects it. It sits in the live store today: eight
    /// performer records in "The Music of Eric Whitacre" carry it.
    func testASentinelIsNeitherRankedNorListed() {
        let handles = ["a", "b", "c", "d", "e", "f", "unknown"]
        let table = Dictionary(uniqueKeysWithValues:
            ["a", "b", "c", "d", "e", "f"].map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        let named = result.suggested.map(\.handle) + result.unranked.map(\.handle)
        XCTAssertFalse(named.contains("unknown"),
                       "a person called unknown must not be offered as one of five invites")
    }

    /// `DPR Dance` is a company display name with a space, the exact value #899
    /// was written about, and it is still in the store on a Battery Dance
    /// Festival performer. Shaped wrong rather than sentinel, so it is the
    /// other half of the predicate.
    func testADisplayNameWithASpaceIsNeitherRankedNorListed() {
        let handles = ["a", "b", "c", "d", "e", "f", "DPR Dance"]
        let table = Dictionary(uniqueKeysWithValues:
            ["a", "b", "c", "d", "e", "f"].map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        let named = result.suggested.map(\.handle) + result.unranked.map(\.handle)
        XCTAssertFalse(named.contains(where: { $0.contains(" ") }),
                       "a value with a space is no account and cannot be invited")
    }

    /// The count effect, which is the half a ranking assertion misses. The
    /// count of candidates is what decides whether the day is ranked or simply
    /// named, so junk merely excluded from the ranking would still put a post
    /// with no editorial decision to make into ranking mode.
    func testFiveRealTagsPlusASentinelStillAllFit() {
        let handles = ["a", "b", "c", "d", "e", "unknown"]
        let table = Dictionary(uniqueKeysWithValues:
            ["a", "b", "c", "d", "e"].map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        XCTAssertEqual(result.coverage, .allFit,
                       "five real accounts is five candidates, whatever junk is tagged beside them")
        XCTAssertEqual(result.suggested.count, 5)
    }

    /// The same for the shape half, so neither half is left resting on the
    /// other's test (L178).
    func testFiveRealTagsPlusADisplayNameStillAllFit() {
        let handles = ["a", "b", "c", "d", "e", "DPR Dance"]
        let table = Dictionary(uniqueKeysWithValues:
            ["a", "b", "c", "d", "e"].map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        XCTAssertEqual(result.coverage, .allFit)
        XCTAssertEqual(result.suggested.count, 5)
    }

    /// The positive control for the four above: the same six real accounts,
    /// with nothing junk among them, DO rank. Without it every assertion here
    /// is satisfied by a `suggest` that refuses everything (L159).
    func testSixRealTagsStillRank() {
        let handles = ["a", "b", "c", "d", "e", "f"]
        let table = Dictionary(uniqueKeysWithValues: handles.map { ($0, stats(1_000, 50, 5)) })
        XCTAssertEqual(CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                                stats: lookup(table), asOf: now).coverage,
                       .ranked)
    }

    // MARK: - Engagement quality beats audience size

    func testASmallLiveAudienceOutranksALargeDeadOne() {
        // Dan's own example. A: 10,000 followers, ~10 likes, no comments. B:
        // 2,000 followers, ~50 likes, ~10 comments. B is the better
        // collaborator despite one fifth the audience, because A's audience is
        // either bought, dead, or not being shown the posts.
        //
        // The four filler accounts are LIVE ones (2% to 5%), which they were
        // not before #1005. They sat at 0.2% to 0.5%, so five of the six
        // candidates were below the liveliness floor and the fixture could not
        // show what it claimed: with only three live accounts and five slots,
        // the best of the dead ones legitimately fills one. Now every slot is
        // contested by an account whose audience is actually there, which is
        // the case the assertion is about (L165).
        let table = [
            "bigdead":  stats(10_000, 10, 0),
            "smalllive": stats(2_000, 50, 10),
            "c": stats(1_000, 50, 0), "d": stats(1_000, 40, 0),
            "e": stats(1_000, 30, 0), "f": stats(1_000, 20, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["bigdead", "smalllive", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result.suggested.first?.handle, "smalllive")
        // The large dead audience does not merely rank lower, it does not make
        // the five at all: a 0.1% rate is under the liveliness floor, so every
        // account above the floor comes first however few interactions it has,
        // which is the whole point of the floor sitting over the score.
        XCTAssertFalse(result.suggested.map(\.handle).contains("bigdead"),
                       "10,000 followers bought a slot it did not earn")
    }

    func testACommentCountsForMoreThanALike() {
        // A comment is a stronger signal of a live audience than a like, so two
        // accounts with the same total interactions are not equal.
        let table = [
            "commenters": stats(1_000, 20, 20),
            "likers":     stats(1_000, 40, 0),
            "c": stats(1_000, 1, 0), "d": stats(1_000, 1, 0),
            "e": stats(1_000, 1, 0), "f": stats(1_000, 1, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["likers", "commenters", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result.suggested.first?.handle, "commenters")
    }

    func testATinyAccountDoesNotTopTheListOnAHandfulOfInteractions() {
        // 5 likes on 20 followers is a 25% rate off almost no data. Under the
        // rate metric a 200 follower floor was needed to stop it topping the
        // list. Under total interactions nothing special is needed: 11
        // interactions is simply fewer than 320, which is why that floor could
        // be removed rather than replaced (#1005).
        let table = [
            "tiny": stats(20, 5, 2),
            "real": stats(4_000, 200, 40),
            "c": stats(1_000, 5, 0), "d": stats(1_000, 4, 0),
            "e": stats(1_000, 3, 0), "f": stats(1_000, 2, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["tiny", "real", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result.suggested.first?.handle, "real")
    }

    func testTheAccountWithMoreInteractionsWins() {
        // Both are well over the liveliness floor, so the score decides, and
        // the score is what actually lands on a post: 320 interactions against
        // 80. Under the old rate metric these two tied at 6% and the follower
        // count broke it; now the interactions say it directly.
        let table = [
            "big":   stats(4_000, 200, 40),
            "small": stats(1_000, 50, 10),
            "c": stats(1_000, 1, 0), "d": stats(1_000, 1, 0),
            "e": stats(1_000, 1, 0), "f": stats(1_000, 1, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["small", "big", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result.suggested.first?.handle, "big")
    }

    // MARK: - The first photo bias is hard, not a tiebreak

    func testSomeoneInTheFirstPhotoOutranksAStrongerAccountThatIsNot() {
        let table = [
            "inphoto":  stats(1_000, 10, 0),      // weak
            "elsewhere": stats(5_000, 400, 100),  // far stronger
            "c": stats(1_000, 9, 0), "d": stats(1_000, 8, 0),
            "e": stats(1_000, 7, 0), "f": stats(1_000, 6, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["elsewhere", "inphoto", "c", "d", "e", "f"],
            firstPhoto: ["inphoto"], stats: lookup(table), asOf: now)
        XCTAssertEqual(result.suggested.first?.handle, "inphoto",
                       "the first photo bias is a hard rule, not a tiebreak")
    }

    func testTheStrongestAccountExcludedByTheRuleIsNamed() {
        // Without this line the exclusion is invisible: a venue account with
        // ten times anyone's reach would silently never be offered, and nothing
        // on screen would say why.
        let table = [
            "p1": stats(1_000, 10, 1), "p2": stats(1_000, 9, 1),
            "p3": stats(1_000, 8, 1), "p4": stats(1_000, 7, 1),
            "p5": stats(1_000, 6, 1),
            "venue": stats(50_000, 5_000, 1_000),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["p1", "p2", "p3", "p4", "p5", "venue"],
            firstPhoto: ["p1", "p2", "p3", "p4", "p5"],
            stats: lookup(table), asOf: now)
        XCTAssertEqual(result.suggested.count, 5)
        XCTAssertFalse(result.suggested.map(\.handle).contains("venue"))
        XCTAssertEqual(result.strongestExcluded?.handle, "venue")
    }

    func testAnAccountLeftOutOnItsOwnMeritsIsNotReportedAsExcludedByTheRule() {
        // The line means "excluded PURELY for not being in the first photo". An
        // account that would have missed the cut anyway must not be offered as
        // a swap, or the line stops meaning anything.
        let table = [
            "p1": stats(9_000, 900, 200), "p2": stats(9_000, 890, 200),
            "p3": stats(9_000, 880, 200), "p4": stats(9_000, 870, 200),
            "p5": stats(9_000, 860, 200),
            "weak": stats(1_000, 1, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["p1", "p2", "p3", "p4", "p5", "weak"],
            firstPhoto: ["p1", "p2", "p3", "p4", "p5"],
            stats: lookup(table), asOf: now)
        XCTAssertNil(result.strongestExcluded)
    }

    func testWhenTheFirstPhotoHoldsFewerThanFiveTheRestAreNamedAsFallbacks() {
        let table = [
            "p1": stats(1_000, 10, 1), "p2": stats(1_000, 9, 1),
            "x1": stats(2_000, 100, 20), "x2": stats(2_000, 90, 20),
            "x3": stats(2_000, 80, 20), "x4": stats(2_000, 70, 20),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["p1", "p2", "x1", "x2", "x3", "x4"],
            firstPhoto: ["p1", "p2"], stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.prefix(2).map(\.handle), ["p1", "p2"])
        XCTAssertEqual(result.suggested.count, 5)
        // Named so Dan can see the difference between a first-photo pick and a
        // slot that fell through to whoever was strongest elsewhere.
        XCTAssertEqual(result.fallbacks, ["x1", "x2", "x3"])
    }

    func testASingleImagePostRanksOnEngagementAloneWithNoFallbackLabelling() {
        // No first photo distinction exists, so nothing is a fallback and
        // nothing was excluded by a rule that did not apply.
        let table = [
            "a": stats(5_000, 400, 100), "b": stats(1_000, 10, 1),
            "c": stats(1_000, 9, 1), "d": stats(1_000, 8, 1),
            "e": stats(1_000, 7, 1), "f": stats(1_000, 6, 1),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result.suggested.first?.handle, "a")
        XCTAssertTrue(result.fallbacks.isEmpty)
        XCTAssertNil(result.strongestExcluded)
    }

    func testAnEmptyFirstPhotoSetIsNotTheSameAsNoFirstPhotoAtAll() {
        // A first photo with nobody tagged in it is a real answer: everyone is
        // a fallback, and the suggestion should say so rather than pretending
        // the rule did not apply.
        let table = Dictionary(uniqueKeysWithValues:
            ["a", "b", "c", "d", "e", "f"].map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"],
            firstPhoto: [], stats: lookup(table), asOf: now)
        XCTAssertEqual(result.fallbacks.count, 5)
    }

    // MARK: - Total interactions, with a liveliness floor over it (#1005)

    /// The score is TOTAL WEIGHTED INTERACTIONS, `likes + 3 * comments`.
    ///
    /// Deliberately not "followers times the engagement rate": that is the same
    /// expression, because the rate is interactions over followers and the
    /// followers cancel, and naming it the other way reads as if it combined
    /// two signals when it combines one.
    ///
    /// A liveliness floor sits ABOVE it as an outer key. Measured on the 122
    /// account population committed in #1114: an engagement rate below 0.37%
    /// demotes 7 accounts, with only 4 within 20% of the line, so it does not
    /// cut through a crowded region.

    /// An account with a large audience that nothing engages with.
    ///
    /// carnegiehall as measured on 2026-08-29: 433,555 followers, a 0.08% rate,
    /// 356 likes a post. On raw interactions it is 8th of 78; the floor is what
    /// holds it out, and without one it would take a slot from an account whose
    /// audience actually turns up.
    private func largeDeadAudience() -> AccountStats {
        stats(433_555, 356, 0)
    }

    func testTheScoreIsTotalInteractionsRatherThanARate() {
        // 4,000 followers with 200 likes is a 5% rate; 40,000 with 1,200 is 3%.
        // The rate says the smaller account wins and reach says the larger
        // does. Interactions is what actually lands on a post, and both are
        // well over the floor, so the larger one wins.
        let table = [
            "reaches": stats(40_000, 1_200, 0),
            "engaged": stats(4_000, 200, 0),
            "c": stats(1_000, 10, 0), "d": stats(1_000, 9, 0),
            "e": stats(1_000, 8, 0), "f": stats(1_000, 7, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["engaged", "reaches", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.first?.handle, "reaches")
    }

    func testALargeDeadAudienceIsHeldOutByTheFloor() {
        // The case the design exists to refuse, and the reason the floor is an
        // OUTER key rather than a tiebreak: on interactions alone this account
        // beats every ordinary one here.
        var table = ["carnegiehall": largeDeadAudience()]
        for name in ["a", "b", "c", "d", "e", "f"] {
            table[name] = stats(1_000, 50, 5)
        }
        let result = CollaboratorPick.suggest(
            handles: Array(table.keys).sorted(), firstPhoto: nil,
            stats: lookup(table), asOf: now)

        XCTAssertFalse(result.suggested.map(\.handle).contains("carnegiehall"),
                       "356 likes a post bought a slot off an audience that is not "
                       + "there: \(result.suggested.map(\.handle))")
        XCTAssertEqual(result.suggested.count, 5)
    }

    func testAnAccountOverTheFloorNeverLosesToOneBelowIt() {
        // Stated as its own rule, because the assertion above is also satisfied
        // by an implementation that merely ranks the dead account sixth.
        let table = [
            "dead":  largeDeadAudience(),
            "alive": stats(1_000, 5, 0),
            "c": stats(1_000, 4, 0), "d": stats(1_000, 3, 0),
            "e": stats(1_000, 2, 0), "f": stats(1_000, 1, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["dead", "alive", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.first?.handle, "alive",
                       "an account with 71 times the interactions and a dead audience "
                       + "outranked a live one")
    }

    func testAnAccountJustOverTheFloorIsNotDemoted() {
        // The positive control for the floor (L159). A floor that demoted
        // everything would satisfy both assertions above.
        let table = [
            "justover": stats(100_000, 400, 0),  // 0.40%, over the 0.37% line
            "small": stats(1_000, 5, 0),
            "c": stats(1_000, 4, 0), "d": stats(1_000, 3, 0),
            "e": stats(1_000, 2, 0), "f": stats(1_000, 1, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["justover", "small", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.first?.handle, "justover")
    }

    func testTheTwoHundredFollowerFloorIsGone() {
        // Its written reason was rate specific and dies with the rate metric.
        // Today it demotes a 9 interaction account below two accounts scoring
        // less, which is the wrong answer under the new score.
        let table = [
            "tiny": stats(150, 100, 0),        // 100 interactions, 66% rate
            "c": stats(1_000, 5, 0), "d": stats(1_000, 4, 0),
            "e": stats(1_000, 3, 0), "f": stats(1_000, 2, 0),
            "g": stats(1_000, 1, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["tiny", "c", "d", "e", "f", "g"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.first?.handle, "tiny",
                       "a small account with real interactions is still demoted by a "
                       + "follower floor whose reason no longer exists")
    }

    // MARK: - An account the API refuses is scored on an assumption (#1005)

    /// What #1006 leaves behind: a follower count off the profile page, no
    /// engagement figures at all, and an outcome saying Meta refused.
    private func refusedByTheAPI(_ followers: Int) -> AccountStats {
        AccountStats(followers: followers, recordedOn: now,
                     followersSource: .measured, outcome: .notProfessional)
    }

    func testAnAccountTheApiRefusedIsScoredOnTheAssumedRate() {
        // 2.73%, the 25th percentile of the measured accounts in its follower
        // band, computed from the committed population in #1114. Deliberately
        // pessimistic: what is measured is that the account is unmeasurable.
        let table = [
            "refused": refusedByTheAPI(3_000),   // assumed 3,000 x 2.73% = 81.9
            "measured": stats(1_000, 50, 5),     // 65 interactions
            "c": stats(1_000, 5, 0), "d": stats(1_000, 4, 0),
            "e": stats(1_000, 3, 0), "f": stats(1_000, 2, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["measured", "refused", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.first?.handle, "refused")
    }

    func testAnAssumedScoreSaysItIsAssumedWhereverItRenders() {
        // What is measured is that the account is unmeasurable. The rate is an
        // assumption and must be labelled as one everywhere, or the reason line
        // reports a figure nobody took.
        let table = ["refused": refusedByTheAPI(3_000)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 1, 0)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["refused", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        let reason = result.suggested.first(where: { $0.handle == "refused" })?.reason ?? ""
        XCTAssertTrue(reason.lowercased().contains("assum"), reason)
        XCTAssertFalse(reason.lowercased().contains("not counted yet"),
                       "an account that IS being scored must not also say nobody has "
                       + "counted it: \(reason)")

        let block = CollaboratorPick.captionBlock(result)
        XCTAssertTrue(block.lowercased().contains("assum"),
                      "the file says nothing about the assumption the ranking made:\n"
                      + block)
    }

    func testAnAccountWithNoRecordAtAllIsStillNotScored() {
        // The decision was NARROWED, not reversed. A refusal Meta actually made
        // is a fact about the account; nobody having looked is not.
        let table = ["b": stats(1_000, 50, 5)]
        let result = CollaboratorPick.suggest(
            handles: ["neverlookedat", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertFalse(result.suggested.map(\.handle).contains("neverlookedat"))
        XCTAssertTrue(result.unranked.map(\.handle).contains("neverlookedat"))
    }

    func testAFollowersOnlyRecordIsNotScoredOnTheAssumedRate() {
        // The case the narrowing actually turns on, and the one the first
        // version of this section missed: an account with a follower count Dan
        // typed in and nothing else. It has everything the assumed path needs
        // EXCEPT a refusal from Meta, and the refusal is the whole
        // justification. Scoring it would assume a rate for an account nobody
        // has said anything about.
        //
        // The neighbouring test used an account with no record at all, which
        // is refused a step earlier, so it passed on code with this rule
        // removed and the mutation sweep reported it SURVIVED (L159, L165).
        let table = ["followersonly": AccountStats(followers: 3_000, recordedOn: now,
                                                   followersSource: .typed)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 1, 0)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["followersonly", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertFalse(result.suggested.map(\.handle).contains("followersonly"),
                       "a follower count with nothing behind it was scored on an "
                       + "assumption nobody is entitled to make")
        XCTAssertTrue(result.unranked.map(\.handle).contains("followersonly"))
    }

    func testARefusedAccountWithNoFollowerCountIsNotScoredEither() {
        // The assumption is a RATE, so it needs a follower count to apply to.
        // Without one there is nothing to assume against, and inventing a
        // number is the thing this whole design refuses.
        let table = ["refused": AccountStats(recordedOn: now, outcome: .notProfessional)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 1, 0)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["refused", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertTrue(result.unranked.map(\.handle).contains("refused"))
    }

    func testAnAccountMarkedPrivateRanksLastHoweverStrongItIs() {
        // #982's mark, as the outermost key. An invite to a private account
        // cannot put the post on a grid anybody can see, so the slot is wasted
        // however good the figures are.
        var strong = stats(50_000, 5_000, 1_000)
        strong.isPrivate = true
        let table = ["private": strong]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 1, 0)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["private", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertFalse(result.suggested.map(\.handle).contains("private"),
                       "a private account took a slot from five that can accept")
    }

    func testAPrivateAccountIsNotSilentlyDropped() {
        // Ranked last is not the same as gone. Dan marked it himself, so he has
        // to be able to see the app has honoured the mark rather than lost the
        // account (L152).
        var strong = stats(50_000, 5_000, 1_000)
        strong.isPrivate = true
        let table = ["private": strong, "b": stats(1_000, 1, 0)]
        let result = CollaboratorPick.suggest(
            handles: ["private", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        let named = result.suggested.map(\.handle) + result.unranked.map(\.handle)
        XCTAssertTrue(named.contains("private"), "the account vanished entirely")
    }

    // MARK: - A withheld like count is not a measured zero (#1032)

    /// Some accounts answer everything except their like count. Folded into the
    /// score as zero, an account doing perfectly well is scored identically to
    /// one measured and found dead, and the liveliness floor then demotes it.
    ///
    /// It is a THIRD thing, not a missing value and not a measurement: the
    /// account answered and refused this one figure (L507). Measured on the
    /// committed population: 2 of 122 accounts withhold it.
    ///
    /// Scored the way an account Meta refuses entirely is scored, on the
    /// assumed rate. Estimating the hidden likes from the comments was the
    /// obvious alternative and the population rules it out: likes per comment
    /// spreads 11x between the 10th and 90th percentile across the 52 accounts
    /// with both figures, so the estimate would be guesswork wearing a number.
    /// The assumed rate lands within 5% of the median estimate for the two real
    /// cases without inheriting that spread.

    /// An account that answered, withheld its likes, and has real comments.
    private func withheldLikes(followers: Int, comments: Int) -> AccountStats {
        AccountStats(followers: followers, likes: nil, comments: comments,
                     recordedOn: now, followersSource: .measured,
                     likesSource: .hidden, commentsSource: .measured,
                     outcome: .measured)
    }

    func testAnAccountThatWithholdsItsLikesIsNotScoredAsHavingNone() {
        // 15,456 followers and 14 comments, one of the two real cases. On
        // comments alone it scores 42; on the assumed rate it scores 422, which
        // is what an account that size with 14 comments a post plausibly gets.
        let table = ["hidden": withheldLikes(followers: 15_456, comments: 14),
                     "b": stats(1_000, 50, 5)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["c", "d", "e", "f"].map { ($0, stats(1_000, 40, 4)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["hidden", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.first?.handle, "hidden",
                       "an account withholding one figure was scored as though that "
                       + "figure had been measured at zero")
    }

    func testAnAccountMeasuredAtGenuinelyZeroIsStillScoredAtZero() {
        // The positive control the issue asks for, in the same fixture shape.
        // Without it the assertion above is satisfied by scoring every account
        // on the assumed rate, which would stop the ranking measuring anything.
        let table = ["zero": AccountStats(followers: 15_456, likes: 0, comments: 0,
                                          recordedOn: now, followersSource: .measured,
                                          likesSource: .measured,
                                          commentsSource: .measured, outcome: .measured),
                     "b": stats(1_000, 50, 5)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["c", "d", "e", "f"].map { ($0, stats(1_000, 40, 4)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["zero", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertNotEqual(result.suggested.first?.handle, "zero",
                          "an account measured and found dead was promoted as though "
                          + "its figures had been withheld")
    }

    func testAWithheldLikeCountIsLabelledWhereverItRenders() {
        // The same shape #1005 labels an assumed rate, and for the same reason:
        // the score rests on an assumption, and a reason line reporting it as a
        // measurement claims something nobody took.
        let table = ["hidden": withheldLikes(followers: 15_456, comments: 14)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 1, 0)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["hidden", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        let reason = result.suggested.first(where: { $0.handle == "hidden" })?.reason ?? ""
        XCTAssertTrue(reason.lowercased().contains("hidden")
                      || reason.lowercased().contains("withheld"), reason)
        XCTAssertTrue(reason.lowercased().contains("assum"), reason)
        XCTAssertFalse(reason.contains("0 likes"),
                       "the reason line reports a zero nobody measured: \(reason)")

        XCTAssertTrue(CollaboratorPick.captionBlock(result).lowercased().contains("hidden"),
                      "CAPTIONS.txt says nothing about the figure that was withheld")
    }

    func testAWithheldLikeCountSaysSomethingDifferentFromAnApiRefusal() {
        // Two causes, two messages (L11). One account answered and kept a
        // figure back; the other was never reported on at all, and the remedies
        // differ: the first may start answering, the second never will.
        let hidden = ["hidden": withheldLikes(followers: 3_000, comments: 14)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 1, 0)) })) { a, _ in a }
        let refused = ["refused": refusedByTheAPI(3_000)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 1, 0)) })) { a, _ in a }

        let one = CollaboratorPick.suggest(handles: ["hidden", "b", "c", "d", "e", "f"],
                                           firstPhoto: nil, stats: lookup(hidden), asOf: now)
        let other = CollaboratorPick.suggest(handles: ["refused", "b", "c", "d", "e", "f"],
                                             firstPhoto: nil, stats: lookup(refused), asOf: now)

        let a = one.suggested.first(where: { $0.handle == "hidden" })?.reason ?? ""
        let b = other.suggested.first(where: { $0.handle == "refused" })?.reason ?? ""
        XCTAssertNotEqual(a, b, "both causes render the same sentence: \(a)")
    }

    func testAWithheldLikeCountWithNoFollowersIsStillNotScored() {
        // The assumption is a RATE, so it needs a follower count to apply to,
        // exactly as an API refusal does.
        let table = ["hidden": AccountStats(likes: nil, comments: 14, recordedOn: now,
                                            likesSource: .hidden, outcome: .measured)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 1, 0)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["hidden", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertTrue(result.unranked.map(\.handle).contains("hidden"))
    }

    // MARK: - The reason line describes the metric that exists (#1005)

    func testTheReasonLineNoLongerClaimsAPercentageIsTheScore() {
        let table = ["a": stats(2_000, 50, 10)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 10, 1)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        let reason = result.suggested.first?.reason ?? ""
        XCTAssertTrue(reason.contains("80 interactions"),
                      "the score itself is not shown, so the order cannot be "
                      + "disagreed with: \(reason)")
    }

    func testAnAccountBelowTheFloorSaysWhyItWasDemoted() {
        let table = ["dead": largeDeadAudience(), "b": stats(1_000, 50, 5)]
        let result = CollaboratorPick.suggest(
            handles: ["dead", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        let reason = (result.suggested + result.unranked)
            .first(where: { $0.handle == "dead" })?.reason ?? ""
        XCTAssertTrue(reason.lowercased().contains("audience"), reason)
        XCTAssertTrue(reason.contains("0.1%"),
                      "the rate is what put it below the line, so it is what the "
                      + "line has to show: \(reason)")
    }

    // MARK: - Missing data is unranked, never zero

    func testAnAccountWithNoNumbersIsListedUnrankedRatherThanScoredZero() {
        let table = ["a": stats(1_000, 50, 5), "b": stats(1_000, 40, 5)]
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "nonumbers", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertFalse(result.suggested.map(\.handle).contains("nonumbers"))
        XCTAssertTrue(result.unranked.map(\.handle).contains("nonumbers"))
        XCTAssertNil(result.unranked.first(where: { $0.handle == "nonumbers" })?.rate)
    }

    func testAnUnrankedAccountSaysItHasNoNumbersRatherThanShowingAZero() {
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup([:]), asOf: now)
        let reason = result.unranked.first?.reason ?? ""
        XCTAssertFalse(reason.contains("0%"), reason)
        XCTAssertTrue(reason.lowercased().contains("not counted"), reason)
    }

    func testAnUnrankedFirstPhotoAccountStillSaysItIsInTheFirstPhoto() {
        // The two facts are independent: not knowing the numbers does not make
        // the strongest reason to invite them go away.
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"],
            firstPhoto: ["a"], stats: lookup([:]), asOf: now)
        let a = result.unranked.first(where: { $0.handle == "a" })
        XCTAssertTrue(a?.inFirstPhoto ?? false)
        XCTAssertTrue(a?.reason.lowercased().contains("first photo") ?? false, a?.reason ?? "")
    }

    // MARK: - The reason is visible, not just an order

    func testEverySuggestionShowsTheFiguresItWasRankedOn() {
        // "Done when" #1: the reason visible, not just an ordered list.
        let table = ["a": stats(2_000, 50, 10)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 10, 1)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"],
            firstPhoto: ["a"], stats: lookup(table), asOf: now)
        let reason = result.suggested.first?.reason ?? ""
        XCTAssertTrue(reason.contains("2,000"), reason)
        XCTAssertTrue(reason.contains("50"), reason)
        XCTAssertTrue(reason.contains("10"), reason)
        XCTAssertTrue(reason.lowercased().contains("first photo"), reason)
    }

    // MARK: - Stale numbers still rank, but say so (#280)

    func testAStaleNumberStillRanksAndIsFlagged() {
        let table = [
            "old": stats(5_000, 500, 100, ageDays: AccountStats.staleAfterDays + 60),
            "b": stats(1_000, 10, 1), "c": stats(1_000, 9, 1),
            "d": stats(1_000, 8, 1), "e": stats(1_000, 7, 1), "f": stats(1_000, 6, 1),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["old", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.first?.handle, "old", "better than nothing")
        XCTAssertTrue(result.suggested.first?.reason.lowercased().contains("stale") ?? false,
                      result.suggested.first?.reason ?? "")
    }

    // MARK: - Failure paths

    func testAnUnresolvableFirstPhotoIsRefusedAndSaidOutLoud() {
        // Getting this wrong does not fail loudly: it silently credits the
        // wrong person, and the suggestion looks entirely reasonable. So when
        // first-photo membership cannot be established, the bias is not applied
        // and the suggestion says why.
        let table = Dictionary(uniqueKeysWithValues:
            ["a", "b", "c", "d", "e", "f"].map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"], firstPhoto: nil,
            stats: lookup(table), asOf: now,
            notes: [CollaboratorPick.firstPhotoUnresolvedNote])

        XCTAssertTrue(result.notes.contains(CollaboratorPick.firstPhotoUnresolvedNote))
        XCTAssertTrue(result.suggested.allSatisfy { !$0.inFirstPhoto })
    }

    func testABlankHandleIsNotACandidate() {
        let table = Dictionary(uniqueKeysWithValues:
            ["a", "b", "c", "d", "e"].map { ($0, stats(1_000, 50, 5)) })
        // Five real handles plus blanks is still five candidates, so they fit
        // the slots and none of the blanks is offered as somebody to invite.
        let result = CollaboratorPick.suggest(handles: ["a", "b", "c", "d", "e", "", "  ", "@"],
                                              firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result.coverage, .allFit)
        XCTAssertEqual(result.suggested.map(\.handle).sorted(), ["a", "b", "c", "d", "e"])
    }

    func testAZeroFollowerAccountIsUnrankedRatherThanDividedBy() {
        // A rate is interactions over followers. Zero followers cannot produce
        // one, and must not produce an infinity that sorts first.
        let table = ["zero": AccountStats(followers: 0, likes: 5, comments: 1, recordedOn: now)]
            .merging(Dictionary(uniqueKeysWithValues:
                ["b", "c", "d", "e", "f"].map { ($0, stats(1_000, 10, 1)) })) { a, _ in a }
        let result = CollaboratorPick.suggest(
            handles: ["zero", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertFalse(result.suggested.map(\.handle).contains("zero"))
        XCTAssertTrue(result.unranked.map(\.handle).contains("zero"))
    }

    func testTheOrderIsStableForAccountsThatScoreIdentically() {
        // Otherwise the five names reshuffle every time the panel redraws, and
        // a suggestion that changes with no input changing cannot be trusted.
        let handles = ["f", "e", "d", "c", "b", "a"]
        let table = Dictionary(uniqueKeysWithValues: handles.map { ($0, stats(1_000, 50, 5)) })
        let first = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                             stats: lookup(table), asOf: now)
        let again = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                             stats: lookup(table), asOf: now)
        XCTAssertEqual(first.suggested.map(\.handle), again.suggested.map(\.handle))
    }

    func testNoMoreThanInstagramsCollaboratorLimitIsEverSuggested() {
        let handles = (1...30).map { "h\($0)" }
        let table = Dictionary(uniqueKeysWithValues: handles.map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        XCTAssertEqual(result.suggested.count, CollaboratorPick.maxPerPost)
        XCTAssertEqual(CollaboratorPick.maxPerPost, 5, "Instagram, confirmed 2026-08-10")
    }

    // MARK: - Nothing reaches the sort as a defaulted zero (L50)

    func testAnUnrankableAccountCannotReachTheSortAtAll() {
        // The lesson: a value that failed to parse or was never measured must
        // never feed a comparison. Coalesced to zero it compares as a real
        // measurement, lands on one side of the follower floor, and sorts as
        // though it had been counted. So the sort only ever sees candidates
        // whose rate and follower count are values.
        let table = [
            "counted": stats(1_000, 50, 5),
            "nofollowers": AccountStats(followers: nil, likes: 50, comments: 5, recordedOn: now),
            "zerofollowers": AccountStats(followers: 0, likes: 50, comments: 5, recordedOn: now),
            "nointeractions": AccountStats(followers: 5_000, likes: nil, comments: nil,
                                           recordedOn: now),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["counted", "nofollowers", "zerofollowers", "nointeractions", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertEqual(result.suggested.map(\.handle), ["counted"])
        XCTAssertEqual(result.unranked.map(\.handle).sorted(),
                       ["e", "f", "nofollowers", "nointeractions", "zerofollowers"])
        // None of them carries a score, not even a zero one.
        for candidate in result.unranked { XCTAssertNil(candidate.rate) }
    }

    // MARK: - A book that could not be read is not an empty book (L10)

    func testANoteAboutAnUnreadableBookReachesTheSuggestion() {
        // Every account reading as "not counted yet" is what an unreadable
        // store looks like from here, and it is indistinguishable from a book
        // nobody has filled in. So the reason is carried rather than inferred.
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"], firstPhoto: nil,
            stats: lookup([:]), asOf: now, notes: [AccountBook.unreadableNote(file: "accounts.json", folder: "~/Library/Application Support/PostRoll")])
        XCTAssertTrue(result.notes.contains(AccountBook.unreadableNote(file: "accounts.json", folder: "~/Library/Application Support/PostRoll")))
    }

    func testTheUnreadableNoteSaysWhatIsWrongRatherThanThatSomethingIs() {
        // "The suggestion is wrong" is not an actionable message. It must also
        // name the file and the folder, because the only fix is on disk and
        // "the file" identifies nothing to somebody standing in Finder (#505).
        let note = AccountBook.unreadableNote(file: "accounts.json",
                                              folder: "~/Library/Application Support/PostRoll")
        XCTAssertTrue(note.lowercased().contains("could not"), note)
        XCTAssertTrue(note.lowercased().contains("not counted"), note)
        XCTAssertTrue(note.contains("accounts.json"), note)
        XCTAssertTrue(note.contains("~/Library/Application Support/PostRoll"), note)
    }

    // MARK: - More candidates than slots and nothing to choose between them (#1115)

    /// The fourth answer. Before it, this day came back `.ranked` with an EMPTY
    /// `suggested`, so both surfaces promised a decision and then named nobody:
    /// "Invite these:" over nothing at all.
    ///
    /// It is the live case rather than an edge one. Measured 2026-08-31, the
    /// account book held nine records, six with a follower count and none with
    /// likes or comments, so `hasEngagementData` was false for every one of
    /// them and every reel day on every real event took this path.

    /// Seven tagged accounts, none of them counted.
    private var nothingCountable: CollaboratorPick.Result {
        CollaboratorPick.suggest(handles: ["a", "b", "c", "d", "e", "f", "g"],
                                 firstPhoto: nil, stats: lookup([:]), asOf: now)
    }

    /// The same seven, with one account counted. The positive control for every
    /// assertion below: without it they are all satisfied by a `suggest` that
    /// never ranks anything at all (L159).
    private var oneOfSevenCounted: CollaboratorPick.Result {
        CollaboratorPick.suggest(handles: ["a", "b", "c", "d", "e", "f", "g"],
                                 firstPhoto: nil,
                                 stats: lookup(["d": stats(1_000, 50, 5)]), asOf: now)
    }

    func testADayWithMoreTagsThanSlotsAndNoFiguresIsItsOwnAnswer() {
        let result = nothingCountable
        XCTAssertEqual(result.coverage, .nothingToRank)
        XCTAssertTrue(result.suggested.isEmpty,
                      "there is nothing to invite, so nothing may be offered as an invite")
        XCTAssertEqual(result.unranked.map(\.handle),
                       ["a", "b", "c", "d", "e", "f", "g"],
                       "every tagged account is named, so it is visible who is waiting "
                       + "on figures")
    }

    func testOneCountedAccountOutOfSevenStillRanks() {
        // The positive control (L159). The refusal above must be a refusal
        // about THIS condition, not a `suggest` that cannot rank at all.
        let result = oneOfSevenCounted
        XCTAssertEqual(result.coverage, .ranked)
        XCTAssertEqual(result.suggested.map(\.handle), ["d"])
    }

    func testTheCaptionsFileSaysThereIsNothingToRankRatherThanInviteThese() {
        let block = CollaboratorPick.captionBlock(nothingCountable)
        XCTAssertFalse(block.contains("Invite these"), """
            CAPTIONS.txt promises a decision and then names nobody:

            \(block)
            """)
        XCTAssertTrue(block.contains("nothing to rank"), block)
        XCTAssertTrue(block.contains("7 accounts are tagged"), block)
        XCTAssertTrue(block.contains("a, b, c, d, e, f, g"),
                      "the accounts waiting on figures are named: \(block)")

        // The same assertion the other way round, so "Invite these" is proved
        // to be what this file says when there IS something to rank.
        XCTAssertTrue(CollaboratorPick.captionBlock(oneOfSevenCounted)
                        .contains("Invite these"))
    }

    func testTheScreenSaysThereIsNothingToRankRatherThanPromisingAList() {
        let line = CollaboratorPick.panelSubtitle(for: nothingCountable)
        XCTAssertTrue(line.contains("nothing to rank"), line)
        XCTAssertTrue(line.contains("7 accounts are tagged"), line)
        XCTAssertTrue(line.contains("Add numbers"),
                      "the way out is named on the screen that reports the state: \(line)")

        XCTAssertNotEqual(CollaboratorPick.panelSubtitle(for: oneOfSevenCounted), line,
                          "a day that can be ranked and a day that cannot must not read "
                          + "alike")
    }

    func testThePanelDrawsItsSentenceFromTheSharedWording() {
        // Naming the sentence where a check can read it proves nothing on its
        // own: typed back into the view it would leave the constant correct,
        // unread and passing (#622, L3, L46). So the panel may hold no subtitle
        // literal of its own.
        let relative = "Sources/Views/CollaboratorPanel.swift"
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent(relative)
        let code = SwiftSourceText.withoutComments(
            try! String(contentsOf: url, encoding: .utf8))

        for phrase in ["Instagram allows", "nothing to rank", "collaborator invite"] {
            XCTAssertFalse(code.lowercased().contains(phrase.lowercased()), """
                \(relative) spells "\(phrase)" itself. The four answers are worded in \
                CollaboratorPick so the screen and CAPTIONS.txt cannot disagree, and a \
                sentence typed back in here is the drift that guard exists to prevent.
                """)
        }

        XCTAssertTrue(code.contains("CollaboratorPick.panelSubtitle"),
                      "\(relative) does not draw the shared sentence at all")
    }

    func testTheSortCannotDefaultAMissingFigureToZero() {
        // Derived from the source, not from behaviour: the two tests above pass
        // whether or not a `?? 0` exists, because the caller filters first. This
        // is the one that catches the pattern coming back, on the day it lands.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // PostRollApp
            .appendingPathComponent("Sources/Services/CollaboratorPick.swift")
        let text = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.isEmpty, "could not read the source to check it")

        // The scoring function legitimately treats absent likes or comments as
        // none of them, which is a different thing: interactions add up, so a
        // missing half is zero of that half. What must never happen is a
        // FOLLOWER count or a RATE reaching a comparison as a defaulted zero.
        for banned in ["followers ?? 0", "rate ?? 0"] {
            XCTAssertFalse(text.contains(banned),
                           "\(banned) turns 'nobody counted this' into 'this scored zero'")
        }
    }
}
