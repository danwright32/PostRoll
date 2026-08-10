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

    func testUnreadableBytesBlockTheSaveThatWouldOverwriteThem() throws {
        // The file is the only copy of every number Dan has typed. Writing over
        // bytes we could not read destroys data precisely because we could not
        // read it.
        let url = root.appendingPathComponent("accounts.json")
        try Data("this is not json".utf8).write(to: url)

        let reopened = AccountBook(fileURL: url)
        XCTAssertEqual(reopened.loadStatus, .unreadable)
        reopened.record(handle: "janecellist", followers: 2_000, likes: 50, comments: 10, on: stamp)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "this is not json", "the bad file was overwritten")
    }

    func testAMissingFileIsAFirstLaunchNotAFailure() {
        let fresh = AccountBook(fileURL: root.appendingPathComponent("nothing-here.json"))
        XCTAssertEqual(fresh.loadStatus, .ok)
        XCTAssertTrue(fresh.all.isEmpty)
        fresh.record(handle: "janecellist", followers: 1, likes: 1, comments: 1, on: stamp)
        XCTAssertEqual(fresh.stats(for: "janecellist")?.followers, 1)
    }

    func testANegativeNumberIsRefusedRatherThanStored() {
        // A negative follower count can only be a typo, and it would produce a
        // negative engagement rate that sorts above every real account.
        book.record(handle: "typo", followers: -5, likes: 50, comments: 10, on: stamp)
        XCTAssertNil(book.stats(for: "typo")?.followers)
    }
}
