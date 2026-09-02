import XCTest

/// #280: remembered numbers carry the date they were entered, and say when
/// they have aged.
///
/// Follower counts and engagement rates age, so a number entered once and kept
/// forever would quietly drive the collaborator ranking in #278 long after it
/// stopped being true, and the ranking would look just as confident either way.
///
/// A stale number still ranks (it is better than nothing) but must be visibly
/// flagged rather than silently trusted.
@MainActor
final class AccountFreshnessTests: XCTestCase {

    private var root: URL!
    private var book: AccountBook!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        book = AccountBook(fileURL: root.appendingPathComponent("accounts.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let entered = Date(timeIntervalSince1970: 1_775_000_000)   // 2026-03-31
    private func days(_ n: Int) -> TimeInterval { TimeInterval(n) * 86_400 }

    // MARK: - The stamp

    func testEnteringNumbersStampsTheDate() {
        book.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: entered)
        XCTAssertEqual(book.stats(for: "janecellist")?.recordedOn, entered)
    }

    func testUpdatingInPlaceMovesTheStampForward() {
        // The one step update: same handle, new figures, and the date has to
        // move or the correction would still read as stale.
        book.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: entered)
        let later = entered.addingTimeInterval(days(400))
        book.record(handle: "@JaneCellist", followers: 2_500, likes: 60, comments: 12, on: later)

        XCTAssertEqual(book.all.count, 1, "an update, not a second record")
        XCTAssertEqual(book.stats(for: "janecellist")?.followers, 2_500)
        XCTAssertEqual(book.stats(for: "janecellist")?.recordedOn, later)
        XCTAssertEqual(book.stats(for: "janecellist")?.freshness(asOf: later), .fresh)
    }

    // MARK: - Fresh, stale, unknown are three different answers

    func testANumberEnteredTodayIsFresh() {
        let stats = AccountStats(followers: 2_000, likes: 50, comments: 10, recordedOn: entered)
        XCTAssertEqual(stats.freshness(asOf: entered), .fresh)
    }

    func testANumberOlderThanTheWindowIsStaleAndSaysHowOld() {
        let now = entered.addingTimeInterval(days(AccountStats.staleAfterDays + 5))
        let stats = AccountStats(followers: 2_000, likes: 50, comments: 10, recordedOn: entered)
        XCTAssertEqual(stats.freshness(asOf: now),
                       .stale(daysOld: AccountStats.staleAfterDays + 5))
    }

    func testTheBoundaryIsNotStaleUntilItIsPast() {
        let stats = AccountStats(followers: 2_000, likes: 50, comments: 10, recordedOn: entered)
        let onTheDay = entered.addingTimeInterval(days(AccountStats.staleAfterDays))
        XCTAssertEqual(stats.freshness(asOf: onTheDay), .fresh)
        XCTAssertEqual(stats.freshness(asOf: onTheDay.addingTimeInterval(days(1))),
                       .stale(daysOld: AccountStats.staleAfterDays + 1))
    }

    func testAnUncountedAccountIsUnknownNotStale() {
        // Never counted and counted-long-ago are different facts, and the
        // second is worth ranking on while the first is not.
        XCTAssertEqual(AccountStats().freshness(asOf: entered), .unknown)
    }

    func testNumbersWithNoStampAreUnknownRatherThanAssumedFresh() {
        // A record written before this field existed has no date. Treating it
        // as entered today would be an assertion nothing measured.
        let stats = AccountStats(followers: 2_000, likes: 50, comments: 10, recordedOn: nil)
        XCTAssertEqual(stats.freshness(asOf: entered), .unknown)
    }

    func testAStampInTheFutureIsNotTreatedAsStale() {
        // A clock change should not make a fresh number read as ancient, nor
        // produce a negative age in the label.
        let stats = AccountStats(followers: 2_000, likes: 50, comments: 10,
                                 recordedOn: entered.addingTimeInterval(days(30)))
        XCTAssertEqual(stats.freshness(asOf: entered), .fresh)
    }

    // MARK: - It says so on screen

    func testTheDateIsShownWhereverTheNumberIs() {
        let stats = AccountStats(followers: 2_000, likes: 50, comments: 10, recordedOn: entered)
        let label = stats.freshnessLabel(asOf: entered)
        XCTAssertTrue(label.contains("Mar 31, 2026"), label)
    }

    func testAStaleNumberSaysSoRatherThanJustShowingItsDate() {
        let now = entered.addingTimeInterval(days(400))
        let label = AccountStats(followers: 2_000, likes: 50, comments: 10, recordedOn: entered)
            .freshnessLabel(asOf: now)
        XCTAssertTrue(label.lowercased().contains("stale"), label)
        XCTAssertTrue(label.contains("Mar 31, 2026"), label)
    }

    func testAnUncountedAccountSaysItHasNoNumbersRatherThanShowingABlank() {
        // A blank where a figure goes reads as a number that failed to load.
        let label = AccountStats().freshnessLabel(asOf: entered)
        XCTAssertFalse(label.isEmpty)
        XCTAssertFalse(label.contains("0"), label)
        XCTAssertTrue(label.lowercased().contains("not counted"), label)
    }

    func testTheLabelIsTheSameInEveryLocale() {
        // Rendered through a fixed POSIX formatter, not the host's, so the
        // string a test pins is the string Dan sees.
        let stats = AccountStats(followers: 1, likes: 1, comments: 1, recordedOn: entered)
        XCTAssertTrue(stats.freshnessLabel(asOf: entered).contains("Mar 31, 2026"))
    }

    // MARK: - The post mix has a reader (#1003)

    /// The mix is stored so that a figure jumping between fetches can be
    /// explained. Measured on the 2026-08-29 sample: reels drew 1.29x feed
    /// likes at the median, and 11 of 46 accounts differed by more than double,
    /// so a jump is often what the account posted rather than who is watching.
    ///
    /// Stored with no reader it would be a field written and never read, which
    /// is indistinguishable from one that works (L46). This is the reader.

    private func stats(likes: Int, reels: Int, feed: Int) -> AccountStats {
        AccountStats(followers: 1_000, likes: likes, comments: 5,
                     recordedOn: Date(timeIntervalSince1970: 1_775_000_000),
                     outcome: .measured, reels: reels, feed: feed)
    }

    func testAFigureThatJumpedWhileTheMixMovedSaysSo() {
        let note = AccountStats.mixNote(before: stats(likes: 100, reels: 0, feed: 10),
                                        after: stats(likes: 300, reels: 10, feed: 0))

        let text = try! XCTUnwrap(note)
        XCTAssertTrue(text.lowercased().contains("reel"), text)
        XCTAssertTrue(text.lowercased().contains("more") || text.lowercased().contains("posted"),
                      "the note has to say the ACCOUNT changed what it posts, not that "
                      + "its audience grew: \(text)")
    }

    func testAFigureThatJumpedWithTheMixUnchangedIsNotExplainedAway() {
        // The positive control (L159), and the more important direction. A note
        // on every jump would explain away real audience growth, which is the
        // thing the ranking exists to notice.
        XCTAssertNil(AccountStats.mixNote(before: stats(likes: 100, reels: 5, feed: 5),
                                          after: stats(likes: 300, reels: 5, feed: 5)))
    }

    func testAMixThatMovedWithoutMovingTheFigureSaysNothing() {
        // Nothing to explain, so nothing to say. A note here would be noise on
        // every ordinary refetch.
        XCTAssertNil(AccountStats.mixNote(before: stats(likes: 100, reels: 0, feed: 10),
                                          after: stats(likes: 104, reels: 10, feed: 0)))
    }

    func testNoMixRecordedAtAllExplainsNothing() {
        // Every record written before the mix existed. An absent mix must not
        // read as a mix of zero reels, which would look like a total shift on
        // the first fetch that records one.
        let before = AccountStats(followers: 1_000, likes: 100, outcome: .measured)

        XCTAssertNil(AccountStats.mixNote(before: before,
                                          after: stats(likes: 300, reels: 10, feed: 0)))
    }

    // MARK: - Followers only is its own state (#977)

    /// Dan entered 12,700 followers for an account, left likes and comments
    /// empty, and saved. The row still read "Not counted yet", and so did the
    /// foot of the dialog with 12,700 sitting in the field above it.
    ///
    /// The number saved. The rule that a follower count alone cannot produce an
    /// engagement rate is correct and is not what changes. What was wrong is
    /// that one label served two states with different remedies: nobody has
    /// ever opened this account, and this one needs one more figure. Reporting
    /// that nothing was entered immediately after something was is the state
    /// most likely to make somebody enter it again.

    private var followersOnly: AccountStats {
        AccountStats(followers: 12_700, recordedOn: Date(timeIntervalSince1970: 1_775_000_000),
                     followersSource: .typed)
    }

    func testAnAccountNobodyHasOpenedIsCountedNever() {
        XCTAssertEqual(AccountStats().countedness, .neverCounted)
    }

    func testAFollowerCountAloneIsItsOwnState() {
        XCTAssertEqual(followersOnly.countedness, .followersOnly)
    }

    func testEnoughToRankIsCounted() {
        XCTAssertEqual(AccountStats(followers: 1_000, likes: 50, comments: 5,
                                    recordedOn: Date()).countedness, .counted)
    }

    func testTheThreeStatesDoNotShareALabel() {
        // The defect itself. Two of these were the same string, so the surface
        // reported that nothing was entered immediately after something was.
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let labels = [
            AccountStats().freshnessLabel(asOf: now),
            followersOnly.freshnessLabel(asOf: now),
            AccountStats(followers: 1_000, likes: 50, comments: 5,
                         recordedOn: now).freshnessLabel(asOf: now),
        ]

        XCTAssertEqual(Set(labels).count, 3, "two states share a label: \(labels)")
    }

    func testTheFollowersOnlyLabelNamesWhatIsMissing() {
        // A label saying only that something is wrong leaves the person to
        // guess which of three fields to go back for (L111).
        let label = followersOnly.freshnessLabel(asOf: Date(timeIntervalSince1970: 1_775_000_000))

        XCTAssertTrue(label.lowercased().contains("likes"), label)
        XCTAssertTrue(label.lowercased().contains("comments"), label)
        XCTAssertFalse(label.lowercased().contains("not counted yet"),
                       "a record holding a follower count and a date still reports "
                       + "that nothing was entered: \(label)")
    }

    func testAnAccountScoredOnAnAssumptionIsNotCalledFollowersOnly() {
        // The positive control (L159). An account Meta refused also has a
        // follower count and no engagement figures, and it IS ranked, so
        // telling it to add likes would name a remedy that changes nothing.
        let refused = AccountStats(followers: 944, recordedOn: Date(),
                                   followersSource: .measured, outcome: .notProfessional)

        XCTAssertNotEqual(refused.countedness, .followersOnly)
    }

    func testAnAccountWithHiddenLikesIsNotCalledFollowersOnlyEither() {
        // Deliberately with NO comment figure either. An account that hid its
        // likes and did report comments is already counted a branch earlier,
        // through `hasEngagementData`, so a fixture carrying comments does not
        // reach the rule this is about and passed with that rule removed: the
        // mutation sweep reported SURVIVED (L159, L165).
        //
        // It is the narrow case, and it is the one that would otherwise be
        // told to add likes the account is refusing to show.
        let hidden = AccountStats(followers: 5_244, likes: nil, comments: nil,
                                  recordedOn: Date(), followersSource: .measured,
                                  likesSource: .hidden, outcome: .measured)

        XCTAssertNotEqual(hidden.countedness, .followersOnly)
        XCTAssertEqual(hidden.countedness, .counted)
    }

    func testAnAccountWithHiddenLikesAndRealCommentsIsCountedToo() {
        // The commoner shape, and the positive control for the narrow one
        // above: both of the real accounts that withhold likes do report
        // comments.
        let hidden = AccountStats(followers: 5_244, comments: 8, recordedOn: Date(),
                                  followersSource: .measured, likesSource: .hidden,
                                  outcome: .measured)

        XCTAssertEqual(hidden.countedness, .counted)
    }

    func testTheDialogSaysTheRequirementBeforeTheFieldsRatherThanAfterTheSave() {
        // The copy described three independent optional fields. That is true of
        // each field alone and says nothing about the requirement binding them,
        // so somebody who knows a follower count fills in the one field they
        // have and gets nothing, with no statement anywhere that the entry was
        // insufficient.
        let copy = AccountStats.numbersFormRequirement

        XCTAssertTrue(copy.lowercased().contains("likes")
                      || copy.lowercased().contains("comments"), copy)
        XCTAssertTrue(copy.lowercased().contains("rank"), copy)
    }

    func testTheDialogDrawsThatSentenceRatherThanSpellingIt() {
        // Naming it where a check can read it proves nothing on its own: typed
        // back into the view it would leave the constant correct, unread and
        // passing (L3, L46).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/CollaboratorPanel.swift")
        let code = SwiftSourceText.withoutComments(
            try! String(contentsOf: url, encoding: .utf8))

        XCTAssertTrue(code.contains("AccountStats.numbersFormRequirement"),
                      "the numbers dialog does not draw the requirement at all, so "
                      + "nothing on it says a follower count alone will not rank")
    }
}
