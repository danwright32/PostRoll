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

    // MARK: - The threshold

    func testFiveTagsProduceNoSuggestionAtAll() {
        // At five there are exactly as many candidates as slots, so there is no
        // choice to make and nothing worth putting on screen.
        let handles = ["a", "b", "c", "d", "e"]
        let table = Dictionary(uniqueKeysWithValues: handles.map { ($0, stats(1_000, 50, 5)) })
        XCTAssertNil(CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now))
    }

    func testSixTagsProduceASuggestion() {
        let handles = ["a", "b", "c", "d", "e", "f"]
        let table = Dictionary(uniqueKeysWithValues: handles.map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.suggested.count, 5, "never more than Instagram allows")
    }

    func testTheThresholdCountsTagsIncludingOnesWithNoNumbers() {
        // Six tags is six tags. Counting only the rankable ones would make the
        // suggestion appear and disappear as numbers are entered.
        let handles = ["a", "b", "c", "d", "e", "f"]
        let table = ["a": stats(1_000, 50, 5)]
        XCTAssertNotNil(CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                                 stats: lookup(table), asOf: now))
    }

    func testDuplicateSpellingsAreOnePersonAndDoNotInflateTheCount() {
        // Six spellings of five people is five candidates, so no suggestion.
        let handles = ["@jane", "jane", "https://instagram.com/JANE/", "b", "c", "d", "e"]
        let table = Dictionary(uniqueKeysWithValues:
            ["jane", "b", "c", "d", "e"].map { ($0, stats(1_000, 50, 5)) })
        XCTAssertNil(CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now))
    }

    // MARK: - Engagement quality beats audience size

    func testASmallLiveAudienceOutranksALargeDeadOne() {
        // Dan's own example. A: 10,000 followers, ~10 likes, no comments. B:
        // 2,000 followers, ~50 likes, ~10 comments. B is the better
        // collaborator despite one fifth the audience, because A's audience is
        // either bought, dead, or not being shown the posts.
        let table = [
            "bigdead":  stats(10_000, 10, 0),
            "smalllive": stats(2_000, 50, 10),
            "c": stats(1_000, 5, 0), "d": stats(1_000, 4, 0),
            "e": stats(1_000, 3, 0), "f": stats(1_000, 2, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["bigdead", "smalllive", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result?.suggested.first?.handle, "smalllive")
        // The large dead audience does not merely rank lower, it does not make
        // the five at all: a 0.1% rate is beaten by every ordinary account
        // here, which is the whole point of ranking on rate rather than reach.
        XCTAssertFalse(result?.suggested.map(\.handle).contains("bigdead") ?? true,
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
        XCTAssertEqual(result?.suggested.first?.handle, "commenters")
    }

    func testATinyAccountDoesNotTopTheListOnAHandfulOfInteractions() {
        // 5 likes on 20 followers is a 25% rate off almost no data. The floor
        // exists so a rate computed from a handful of interactions cannot
        // outrank a real audience.
        let table = [
            "tiny": stats(20, 5, 2),
            "real": stats(4_000, 200, 40),
            "c": stats(1_000, 5, 0), "d": stats(1_000, 4, 0),
            "e": stats(1_000, 3, 0), "f": stats(1_000, 2, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["tiny", "real", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result?.suggested.first?.handle, "real")
    }

    func testFollowersBreakATieOnEngagementRate() {
        // Rate is the primary sort, but between two identical rates the larger
        // audience reaches more people.
        let table = [
            "big":   stats(4_000, 200, 40),
            "small": stats(1_000, 50, 10),
            "c": stats(1_000, 1, 0), "d": stats(1_000, 1, 0),
            "e": stats(1_000, 1, 0), "f": stats(1_000, 1, 0),
        ]
        let result = CollaboratorPick.suggest(
            handles: ["small", "big", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)
        XCTAssertEqual(result?.suggested.first?.handle, "big")
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
        XCTAssertEqual(result?.suggested.first?.handle, "inphoto",
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
        XCTAssertEqual(result?.suggested.count, 5)
        XCTAssertFalse(result?.suggested.map(\.handle).contains("venue") ?? true)
        XCTAssertEqual(result?.strongestExcluded?.handle, "venue")
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
        XCTAssertNil(result?.strongestExcluded)
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

        XCTAssertEqual(result?.suggested.prefix(2).map(\.handle), ["p1", "p2"])
        XCTAssertEqual(result?.suggested.count, 5)
        // Named so Dan can see the difference between a first-photo pick and a
        // slot that fell through to whoever was strongest elsewhere.
        XCTAssertEqual(result?.fallbacks, ["x1", "x2", "x3"])
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
        XCTAssertEqual(result?.suggested.first?.handle, "a")
        XCTAssertTrue(result?.fallbacks.isEmpty ?? false)
        XCTAssertNil(result?.strongestExcluded)
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
        XCTAssertEqual(result?.fallbacks.count, 5)
    }

    // MARK: - Missing data is unranked, never zero

    func testAnAccountWithNoNumbersIsListedUnrankedRatherThanScoredZero() {
        let table = ["a": stats(1_000, 50, 5), "b": stats(1_000, 40, 5)]
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "nonumbers", "d", "e", "f"],
            firstPhoto: nil, stats: lookup(table), asOf: now)

        XCTAssertFalse(result?.suggested.map(\.handle).contains("nonumbers") ?? true)
        XCTAssertTrue(result?.unranked.map(\.handle).contains("nonumbers") ?? false)
        XCTAssertNil(result?.unranked.first(where: { $0.handle == "nonumbers" })?.rate)
    }

    func testAnUnrankedAccountSaysItHasNoNumbersRatherThanShowingAZero() {
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"],
            firstPhoto: nil, stats: lookup([:]), asOf: now)
        let reason = result?.unranked.first?.reason ?? ""
        XCTAssertFalse(reason.contains("0%"), reason)
        XCTAssertTrue(reason.lowercased().contains("not counted"), reason)
    }

    func testAnUnrankedFirstPhotoAccountStillSaysItIsInTheFirstPhoto() {
        // The two facts are independent: not knowing the numbers does not make
        // the strongest reason to invite them go away.
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"],
            firstPhoto: ["a"], stats: lookup([:]), asOf: now)
        let a = result?.unranked.first(where: { $0.handle == "a" })
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
        let reason = result?.suggested.first?.reason ?? ""
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

        XCTAssertEqual(result?.suggested.first?.handle, "old", "better than nothing")
        XCTAssertTrue(result?.suggested.first?.reason.lowercased().contains("stale") ?? false,
                      result?.suggested.first?.reason ?? "")
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

        XCTAssertTrue(result?.notes.contains(CollaboratorPick.firstPhotoUnresolvedNote) ?? false)
        XCTAssertTrue(result?.suggested.allSatisfy { !$0.inFirstPhoto } ?? false)
    }

    func testABlankHandleIsNotACandidate() {
        let table = Dictionary(uniqueKeysWithValues:
            ["a", "b", "c", "d", "e"].map { ($0, stats(1_000, 50, 5)) })
        // Five real handles plus blanks is still five candidates.
        XCTAssertNil(CollaboratorPick.suggest(handles: ["a", "b", "c", "d", "e", "", "  ", "@"],
                                              firstPhoto: nil, stats: lookup(table), asOf: now))
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
        XCTAssertFalse(result?.suggested.map(\.handle).contains("zero") ?? true)
        XCTAssertTrue(result?.unranked.map(\.handle).contains("zero") ?? false)
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
        XCTAssertEqual(first?.suggested.map(\.handle), again?.suggested.map(\.handle))
    }

    func testNoMoreThanInstagramsCollaboratorLimitIsEverSuggested() {
        let handles = (1...30).map { "h\($0)" }
        let table = Dictionary(uniqueKeysWithValues: handles.map { ($0, stats(1_000, 50, 5)) })
        let result = CollaboratorPick.suggest(handles: handles, firstPhoto: nil,
                                              stats: lookup(table), asOf: now)
        XCTAssertEqual(result?.suggested.count, CollaboratorPick.maxPerPost)
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

        XCTAssertEqual(result?.suggested.map(\.handle), ["counted"])
        XCTAssertEqual(result?.unranked.map(\.handle).sorted(),
                       ["e", "f", "nofollowers", "nointeractions", "zerofollowers"])
        // None of them carries a score, not even a zero one.
        for candidate in result?.unranked ?? [] { XCTAssertNil(candidate.rate) }
    }

    // MARK: - A book that could not be read is not an empty book (L10)

    func testANoteAboutAnUnreadableBookReachesTheSuggestion() {
        // Every account reading as "not counted yet" is what an unreadable
        // store looks like from here, and it is indistinguishable from a book
        // nobody has filled in. So the reason is carried rather than inferred.
        let result = CollaboratorPick.suggest(
            handles: ["a", "b", "c", "d", "e", "f"], firstPhoto: nil,
            stats: lookup([:]), asOf: now, notes: [AccountBook.unreadableNote(file: "accounts.json", folder: "~/Library/Application Support/PostRoll")])
        XCTAssertTrue(result?.notes.contains(AccountBook.unreadableNote(file: "accounts.json", folder: "~/Library/Application Support/PostRoll")) ?? false)
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
