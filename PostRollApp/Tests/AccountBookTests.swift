import XCTest

/// #279: follower and engagement numbers are remembered per handle, between
/// events.
///
/// The collaborator ranking in #278 needs numbers to rank on, and the only
/// source that works without a platform API is Dan entering them. That is only
/// worth doing if the app keeps them: a performer tagged in March should
/// already be scored the next time they turn up, not asked for again.
///
/// Two rules carry most of the weight. Everything is keyed on the bare handle
/// `CaptionBlocks.bareUsername` produces, so `@name`, `name` and a pasted
/// profile URL are one record rather than three. And an account with no numbers
/// yet reads as unknown, never as zero, or it sorts to the bottom of a ranking
/// as though it had been measured and found wanting.
@MainActor
final class AccountBookTests: XCTestCase {

    private var root: URL!
    private var book: AccountBook!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accountbook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        book = AccountBook(fileURL: root.appendingPathComponent("accounts.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let stamp = Date(timeIntervalSince1970: 1_775_000_000)

    // MARK: - One record per account, however it was spelled

    func testEverySpellingOfOneHandleResolvesToOneRecord() {
        book.record(handle: "@janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)
        book.record(handle: "https://instagram.com/JaneCellist/", followers: 2_100,
                    likes: 55, comments: 11, on: stamp)

        XCTAssertEqual(book.all.count, 1, "three spellings, one person")
        XCTAssertEqual(book.stats(for: "janecellist")?.followers, 2_100,
                       "the later entry wins")
        XCTAssertEqual(book.stats(for: "@JANECELLIST")?.followers, 2_100,
                       "lookup is spelling-insensitive too")
    }

    func testTheStoredSpellingIsTheOneToShow() {
        // Instagram handles are case insensitive but people care how theirs
        // reads, so the display spelling is kept even though the key is folded.
        book.record(handle: "@JaneCellist", followers: 2_000, likes: 50, comments: 10, on: stamp)
        XCTAssertEqual(book.all.first?.handle, "JaneCellist")
    }

    // MARK: - Unknown is not zero

    func testAnAccountWithNoNumbersReadsAsUnknownNotZero() {
        book.noteTagged(handles: ["newperformer"], on: stamp)

        let stats = book.stats(for: "newperformer")
        XCTAssertNotNil(stats, "the account is known even though its numbers are not")
        XCTAssertNil(stats?.followers)
        XCTAssertNil(stats?.likes)
        XCTAssertNil(stats?.comments)
        XCTAssertFalse(stats?.hasEngagementData ?? true)
    }

    func testAnAccountNeverSeenAtAllIsNil() {
        XCTAssertNil(book.stats(for: "stranger"))
    }

    func testAPartiallyFilledAccountIsStillNotComplete() {
        // Followers alone cannot produce an engagement rate, and a rate is the
        // thing the ranking sorts on.
        book.record(handle: "halfknown", followers: 5_000, likes: nil, comments: nil, on: stamp)
        XCTAssertFalse(book.stats(for: "halfknown")?.hasEngagementData ?? true)
        XCTAssertEqual(book.stats(for: "halfknown")?.followers, 5_000)
    }

    func testZeroIsARealMeasurementAndIsKept() {
        // An account that genuinely gets no comments must not be confused with
        // one nobody has counted.
        book.record(handle: "quietaccount", followers: 10_000, likes: 10, comments: 0, on: stamp)
        let stats = book.stats(for: "quietaccount")
        XCTAssertEqual(stats?.comments, 0)
        XCTAssertTrue(stats?.hasEngagementData ?? false)
    }

    // MARK: - It doubles as the list of every account ever tagged

    func testNotingTagsBuildsABrowsableListWithoutInventingNumbers() {
        book.noteTagged(handles: ["@one", "two", "https://instagram.com/three"], on: stamp)
        XCTAssertEqual(book.all.map(\.handle).sorted(), ["one", "three", "two"])
        for record in book.all {
            XCTAssertNil(record.stats.followers)
        }
    }

    func testNotingATagAgainDoesNotWipeNumbersAlreadyEntered() {
        // The tagging path runs on every export; it must never be a way to lose
        // figures Dan typed in by hand.
        book.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)
        book.noteTagged(handles: ["@janecellist"], on: stamp.addingTimeInterval(86_400))

        XCTAssertEqual(book.stats(for: "janecellist")?.followers, 2_000)
        XCTAssertEqual(book.stats(for: "janecellist")?.likes, 50)
    }

    func testAnEmptyOrBlankHandleIsNotRecorded() {
        book.noteTagged(handles: ["", "   ", "@"], on: stamp)
        XCTAssertTrue(book.all.isEmpty)
    }

    // MARK: - It survives a relaunch

    func testNumbersOutliveTheProcessThatEnteredThem() throws {
        book.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)

        let reopened = AccountBook(fileURL: root.appendingPathComponent("accounts.json"))
        XCTAssertEqual(reopened.stats(for: "janecellist")?.followers, 2_000)
        XCTAssertEqual(reopened.stats(for: "janecellist")?.comments, 10)
    }

    func testAFieldAddedLaterDoesNotWipeWhatIsAlreadyStored() throws {
        // Every persisted Codable here decodes with decodeIfPresent, because a
        // record written by an older build must survive being read by a newer
        // one rather than failing the whole file.
        let url = root.appendingPathComponent("accounts.json")
        let older = """
        {"records": [{"handle": "janecellist", "stats": {"followers": 2000}}]}
        """
        try Data(older.utf8).write(to: url)

        let reopened = AccountBook(fileURL: url)
        XCTAssertEqual(reopened.stats(for: "janecellist")?.followers, 2_000)
        XCTAssertNil(reopened.stats(for: "janecellist")?.likes)
    }

    // MARK: - Failure paths

    func testBadBytesAreKeptButNoLongerBlockEverySaveForever() throws {
        // The file is the only copy of every number Dan has typed, so bytes we
        // could not read are never written over. They are moved out of the way
        // instead (#505), which is what lets the numbers he types NEXT be saved:
        // leaving them in place switched saving off for good.
        let url = root.appendingPathComponent("accounts.json")
        try Data("this is not json".utf8).write(to: url)

        let reopened = AccountBook(fileURL: url)
        reopened.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)

        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertEqual(aside.count, 1, "the unreadable bytes were not preserved: \(aside)")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(aside[0]), encoding: .utf8),
                       "this is not json")
        XCTAssertEqual(AccountBook(fileURL: url).stats(for: "janecellist")?.followers, 2_000,
                       "numbers entered after the failure were dropped")
    }

    func testAMissingFileIsAFirstLaunchNotAFailure() {
        let fresh = AccountBook(fileURL: root.appendingPathComponent("nothing-here.json"))
        XCTAssertEqual(fresh.loadStatus, .ok)
        XCTAssertTrue(fresh.all.isEmpty)
        fresh.record(handle: "janecellist", followers: 1, likes: 1, comments: 1, on: stamp)
        XCTAssertEqual(fresh.stats(for: "janecellist")?.followers, 1)
    }

    // MARK: - The book the suite itself gets (#945)

    func testTheScratchAccountsFileIsEmptiedBeforeItIsHandedBack() throws {
        // The half a fixed name cannot give on its own: whatever one run wrote
        // is an input to the next unless something clears it (#744). Written
        // as a failure of the CLEARING rather than of the path, because a
        // returned path that merely exists proves nothing.
        let file = AccountBook.scratchAccountsFile()
        try "left behind by an earlier run".write(to: file, atomically: true, encoding: .utf8)
        let sideways = file.deletingLastPathComponent().appendingPathComponent("accounts-backup.json")
        try "and its backup".write(to: sideways, atomically: true, encoding: .utf8)

        let again = AccountBook.scratchAccountsFile()

        XCTAssertEqual(again, file, "the scratch path moved between calls")
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.path),
                       "the scratch accounts file survived, so one run's numbers are the next run's")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sideways.path),
                       "the rotated backup survived, so clearing the file alone is not enough")
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.deletingLastPathComponent().path),
                      "the scratch directory was removed and not put back, so a save into it fails")
    }

    func testTheScratchAccountsFileIsNotTheRealOne() {
        // The point of the redirection, stated where it can be read. The
        // arrangement itself is held in place by the compiler and by
        // tests/test_swift_tests_never_reach_live_data.py; this says what the
        // arrangement is FOR.
        let scratch = AccountBook.scratchAccountsFile()
        // Read into a local first: `root: AppPaths.` written out at a call site
        // is the spelling the live-data guard bans, and it is banned for a good
        // reason, so this does not write it.
        let liveRoot = AppPaths.root
        XCTAssertNotEqual(scratch, AppPaths.accountsFile)
        XCTAssertFalse(AppPaths.isInside(scratch, root: liveRoot),
                       "the suite's accounts file is inside the real data root")
    }

    // MARK: - A fetched record carries where each figure came from (#1003)

    /// `AccountStats` held four numbers and a date, so a figure typed by hand
    /// and one Meta reported were the same thing, and an account the API had
    /// refused was indistinguishable from one nobody had opened.
    ///
    /// The trap this section is mostly about: `record` rebuilt the whole
    /// `AccountStats` from four values, so typing a follower count into the
    /// sheet erased the fetch outcome and silently made that account
    /// unrankable again.

    /// What a completed fetch leaves behind.
    private func fetched() -> AccountStats {
        AccountStats(followers: 3_000, likes: 120, comments: 8, recordedOn: stamp,
                     followersSource: .measured, likesSource: .measured,
                     commentsSource: .measured, outcome: .measured,
                     instagramID: "17841400000000000", reels: 4, feed: 8,
                     isPrivate: false)
    }

    func testTypingANumberInDoesNotEraseWhatTheFetchFoundOut() {
        book.write(fetched(), for: "janecellist")

        book.record(handle: "janecellist", followers: 3_500, likes: nil,
                    comments: nil, on: stamp)

        let stored = book.stats(for: "janecellist")
        XCTAssertEqual(stored?.followers, 3_500, "the typed figure wins, which is the point")
        XCTAssertEqual(stored?.followersSource, .typed)
        XCTAssertEqual(stored?.outcome, .measured,
                       "the fetch outcome was wiped, so this account reads as one "
                       + "nobody has ever asked about and becomes unrankable again")
        XCTAssertEqual(stored?.instagramID, "17841400000000000",
                       "the stable id was wiped, so a later fetch cannot notice the "
                       + "handle changed hands")
        XCTAssertEqual(stored?.reels, 4)
        XCTAssertEqual(stored?.feed, 8)
    }

    func testAFigureSentBackUnchangedIsStillAMeasuredOne() {
        // The sheet is pre-filled with what is stored, so it sends all three
        // figures back whether or not Dan touched them. Marking every one of
        // them typed would quietly downgrade a measured figure the first time
        // he corrected a different field, and the reason line would then claim
        // he had entered a number Meta reported.
        book.write(fetched(), for: "janecellist")

        book.record(handle: "janecellist", followers: 3_500, likes: 120,
                    comments: 8, on: stamp)

        let stored = book.stats(for: "janecellist")
        XCTAssertEqual(stored?.followersSource, .typed, "this one he really did change")
        XCTAssertEqual(stored?.likesSource, .measured, "and these two he did not")
        XCTAssertEqual(stored?.commentsSource, .measured)
    }

    func testClearingAFieldReallyDoesClearTheFigure() {
        // The positive control, and the behaviour the rule above must not
        // break: an emptied box is Dan saying he does not know, which is a real
        // action and the only way to perform it.
        book.write(fetched(), for: "janecellist")

        book.record(handle: "janecellist", followers: 3_500, likes: nil,
                    comments: nil, on: stamp)

        let stored = book.stats(for: "janecellist")
        XCTAssertNil(stored?.likes)
        XCTAssertNil(stored?.likesSource, "a figure nobody knows has no source")
    }

    func testAPrivateMarkSurvivesTypingNumbersIn() {
        // #982's mark is the only mechanism there is: private is not detectable
        // from the logged out page. Losing it on a save means an account Dan
        // marked by hand quietly starts ranking normally again.
        var private_ = fetched()
        private_.isPrivate = true
        book.write(private_, for: "janecellist")

        book.record(handle: "janecellist", followers: 3_500, likes: nil,
                    comments: nil, on: stamp)

        XCTAssertEqual(book.stats(for: "janecellist")?.isPrivate, true)
    }

    func testAFetchThatFailedChangesNothingThatWasAlreadyKnown() {
        book.record(handle: "janecellist", followers: 2_000, likes: 50,
                    comments: 10, on: stamp)

        book.merge(AccountStats(outcome: .networkFailed), for: "janecellist", on: stamp)

        let stored = book.stats(for: "janecellist")
        XCTAssertEqual(stored?.followers, 2_000, "a failed fetch erased a typed figure")
        XCTAssertEqual(stored?.likes, 50)
        XCTAssertEqual(stored?.outcome, .networkFailed,
                       "but the failure is recorded, or nothing knows to retry")
    }

    func testAFollowersOnlyFetchLeavesTypedLikesIntact() {
        book.record(handle: "janecellist", followers: nil, likes: 50,
                    comments: 10, on: stamp)

        book.merge(AccountStats(followers: 9_000, recordedOn: stamp,
                                followersSource: .measured, outcome: .measured),
                   for: "janecellist", on: stamp)

        let stored = book.stats(for: "janecellist")
        XCTAssertEqual(stored?.followers, 9_000)
        XCTAssertEqual(stored?.likes, 50, "the typed likes were thrown away")
        XCTAssertEqual(stored?.likesSource, .typed)
    }

    func testAHandleThatChangedHandsIsNotMergedAcross() {
        // `business_discovery.username(...)` looks up by a MUTABLE display
        // name. Without the stable id, a renamed handle silently attributes one
        // account's audience to whoever holds the name next.
        book.write(fetched(), for: "janecellist")

        book.merge(AccountStats(followers: 900_000, recordedOn: stamp,
                                followersSource: .measured, outcome: .measured,
                                instagramID: "17841499999999999"),
                   for: "janecellist", on: stamp)

        let stored = book.stats(for: "janecellist")
        XCTAssertEqual(stored?.followers, 3_000,
                       "the figures of a different account were merged onto this one")
        XCTAssertEqual(stored?.outcome, .handleChangedHands,
                       "and nothing says why the merge was refused")
    }

    func testAFetchForAnAccountWithNoStoredIdIsMergedNormally() {
        // The positive control (L159). Refusing every merge would satisfy the
        // assertion above, and no account has an id until its first fetch.
        book.record(handle: "janecellist", followers: 2_000, likes: 50,
                    comments: 10, on: stamp)

        book.merge(AccountStats(followers: 9_000, recordedOn: stamp,
                                followersSource: .measured, outcome: .measured,
                                instagramID: "17841400000000000"),
                   for: "janecellist", on: stamp)

        XCTAssertEqual(book.stats(for: "janecellist")?.followers, 9_000)
        XCTAssertEqual(book.stats(for: "janecellist")?.instagramID, "17841400000000000")
    }

    func testANegativeNumberIsRefusedRatherThanStored() {
        // A negative follower count can only be a typo, and it would produce a
        // negative engagement rate that sorts above every real account.
        book.record(handle: "typo", followers: -5, likes: 50, comments: 10, on: stamp)
        XCTAssertNil(book.stats(for: "typo")?.followers)
    }
}
