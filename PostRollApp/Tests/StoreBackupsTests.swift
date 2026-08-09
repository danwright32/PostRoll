import XCTest

/// #102: events.json kept exactly one .bak, and it was copied from whatever
/// happened to be on disk. Two things follow, both bad.
///
/// Save runs on every edit, so one backup slot is erased by ordinary typing
/// long before Dan notices a problem. And because the copy is taken from the
/// current file without looking at it, a degraded file becomes the backup,
/// which means the safety net can be destroyed by the very failure it exists
/// for. #88 wants the same protection on analytics.json, so this is one
/// implementation used by both.
final class StoreBackupsTests: XCTestCase {

    private var dir: URL!
    private var store: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backups_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = dir.appendingPathComponent("events.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ text: String) {
        try? text.write(to: store, atomically: true, encoding: .utf8)
    }

    private var backups: [String] {
        StoreBackups.existing(for: store).map(\.lastPathComponent).sorted()
    }

    /// A stand-in validator: anything starting with "[" is a decodable store.
    private func valid(_ data: Data) -> Bool {
        (String(data: data, encoding: .utf8) ?? "").hasPrefix("[")
    }

    private func rotate(at second: Int, keeping: Int = 5) {
        StoreBackups.rotate(store: store, keeping: keeping, isValid: valid,
                            now: { Date(timeIntervalSince1970: TimeInterval(second)) })
    }

    // MARK: - the good case

    func testAGoodFileIsBackedUp() {
        write("[{\"a\":1}]")
        rotate(at: 1)
        XCTAssertEqual(backups.count, 1)
    }

    func testTheBackupHoldsTheContentAtTheTimeItWasTaken() throws {
        write("[\"first\"]")
        rotate(at: 1)
        write("[\"second\"]")

        let saved = try String(contentsOf: StoreBackups.existing(for: store)[0], encoding: .utf8)
        XCTAssertEqual(saved, "[\"first\"]")
    }

    func testSeveralGenerationsAreKept() {
        for second in 1...4 {
            write("[\(second)]")
            rotate(at: second)
        }
        XCTAssertEqual(backups.count, 4, "one slot is erased by ordinary editing")
    }

    func testOldGenerationsArePrunedToTheLimit() {
        for second in 1...9 {
            write("[\(second)]")
            rotate(at: second, keeping: 3)
        }
        XCTAssertEqual(backups.count, 3, "backups must be bounded, not unbounded")
    }

    func testPruningKeepsTheNewestNotTheOldest() throws {
        for second in 1...5 {
            write("[\(second)]")
            rotate(at: second, keeping: 2)
        }
        let kept = try StoreBackups.existing(for: store)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .sorted()
        XCTAssertEqual(kept, ["[4]", "[5]"])
    }

    // MARK: - the case the single .bak got wrong

    func testABadFileNeverBecomesABackup() {
        write("[\"good\"]")
        rotate(at: 1)

        write("this file is corrupt")
        rotate(at: 2)

        XCTAssertEqual(backups.count, 1, "a corrupt file must not be captured as a backup")
    }

    func testAGoodBackupSurvivesTwoConsecutiveBadSaves() throws {
        // The exact scenario in the issue: with one slot taken from whatever
        // is on disk, two bad states in a row leave nothing recoverable.
        write("[\"the last good state\"]")
        rotate(at: 1)

        write("corrupt one")
        rotate(at: 2)
        write("corrupt two")
        rotate(at: 3)

        let survivors = try StoreBackups.existing(for: store)
            .map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(survivors, ["[\"the last good state\"]"])
    }

    func testAMissingStoreIsNotAnError() {
        rotate(at: 1)
        XCTAssertTrue(backups.isEmpty)
    }

    func testAnEmptyFileIsNotBackedUp() {
        write("")
        rotate(at: 1)
        XCTAssertTrue(backups.isEmpty, "an empty file is not a state worth restoring")
    }

    func testTwoRotationsInTheSameSecondDoNotCollide() {
        write("[\"a\"]")
        rotate(at: 7)
        write("[\"b\"]")
        rotate(at: 7)

        XCTAssertEqual(backups.count, 2,
                       "a same-second collision must not silently overwrite the earlier backup")
    }

    func testBackupsOfOneStoreDoNotCountAsAnothers() {
        write("[\"events\"]")
        rotate(at: 1)

        let other = dir.appendingPathComponent("analytics.json")
        try? "[\"analytics\"]".write(to: other, atomically: true, encoding: .utf8)
        StoreBackups.rotate(store: other, keeping: 5, isValid: valid,
                            now: { Date(timeIntervalSince1970: 2) })

        XCTAssertEqual(StoreBackups.existing(for: store).count, 1)
        XCTAssertEqual(StoreBackups.existing(for: other).count, 1)
    }

    func testTheNewestBackupIsFindableForRestoring() throws {
        for second in 1...3 {
            write("[\(second)]")
            rotate(at: second)
        }
        let newest = try XCTUnwrap(StoreBackups.newest(for: store))
        XCTAssertEqual(try String(contentsOf: newest, encoding: .utf8), "[3]")
    }
}

/// #88: a failed analytics.json decode reached an NSLog and nothing else, so
/// the entire imported Instagram history could be set aside and all Dan would
/// see is an empty Insights screen. An empty state reads as "nothing imported
/// yet"; it is not the same screen as "your data could not be read".
final class AnalyticsRecoveryMessageTests: XCTestCase {

    func testItSaysTheHistoryCouldNotBeRead() {
        let text = AnalyticsStore.recoveryText(setAsideAs: "analytics.json.broken", restorable: false)
        XCTAssertTrue(text.contains("could not be read"), text)
    }

    func testItNamesWhereTheUnreadableFileWent() {
        let text = AnalyticsStore.recoveryText(setAsideAs: "analytics.json.broken", restorable: false)
        XCTAssertTrue(text.contains("Nothing was deleted"), text)
        XCTAssertTrue(text.contains("analytics.json.broken"), text)
    }

    func testItAdmitsWhenTheFileCouldNotEvenBeSetAside() {
        // Claiming "nothing was deleted, it was set aside as ..." when the
        // set-aside failed would be a promise the code did not keep.
        let text = AnalyticsStore.recoveryText(setAsideAs: nil, restorable: false)
        XCTAssertTrue(text.contains("could not be set aside"), text)
        XCTAssertFalse(text.contains("Nothing was deleted"), text)
    }

    func testItSaysWhetherThereIsAnythingToRestore() {
        let with = AnalyticsStore.recoveryText(setAsideAs: "x", restorable: true)
        let without = AnalyticsStore.recoveryText(setAsideAs: "x", restorable: false)
        XCTAssertTrue(with.contains("can be restored"), with)
        XCTAssertTrue(without.contains("no earlier backup"), without)
    }
}

/// #88 on the real store, not just the message text: the load and save paths
/// have to actually use the backup ring and actually set the warning. A
/// message nobody sets is the same as no message.
/// Not `@MainActor` on the class: Xcode 16.4 on CI then rejects both a
/// synchronous setUp (nonisolated, cannot touch the properties) and an async
/// one (sending a non-Sendable XCTestCase). Isolating each test method instead
/// works on both toolchains.
final class AnalyticsStoreRecoveryTests: XCTestCase {

    private var dir: URL!
    private var file: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("analytics.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    @MainActor
    func testACleanLoadReportsNoProblem() {
        let store = AnalyticsStore(fileURL: file)
        XCTAssertNil(store.recoveryMessage)
    }

    @MainActor
    func testAnUnreadableFileSetsTheWarningRatherThanLoadingEmptySilently() throws {
        try "this is not analytics json".write(to: file, atomically: true, encoding: .utf8)

        let store = AnalyticsStore(fileURL: file)

        let message = try XCTUnwrap(store.recoveryMessage,
                                    "an empty Insights screen reads as 'nothing imported yet'")
        XCTAssertTrue(message.contains("could not be read"), message)
        XCTAssertTrue(store.posts.isEmpty)
    }

    @MainActor
    func testTheUnreadableFileIsSetAsideAndNamedInTheWarning() throws {
        try "not json".write(to: file, atomically: true, encoding: .utf8)

        let store = AnalyticsStore(fileURL: file)

        let message = try XCTUnwrap(store.recoveryMessage)
        XCTAssertTrue(message.contains("Nothing was deleted"), message)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(leftovers.contains { $0 != "analytics.json" },
                      "the unreadable bytes must still exist somewhere: \(leftovers)")
    }

    @MainActor
    func testSavingKeepsABackupOfThePreviousGoodFile() throws {
        let store = AnalyticsStore(fileURL: file)
        store.orgFollowerBands = ["Org A": .under1k]
        store.save()
        XCTAssertTrue(StoreBackups.existing(for: file).isEmpty,
                      "nothing to back up before the first write")

        store.orgFollowerBands = ["Org B": .under1k]
        store.save()

        XCTAssertEqual(StoreBackups.existing(for: file).count, 1,
                       "the previous good analytics.json must be recoverable")
    }

    @MainActor
    func testACorruptAnalyticsFileIsNotCapturedAsABackup() throws {
        let store = AnalyticsStore(fileURL: file)
        store.orgFollowerBands = ["Org A": .under1k]
        store.save()
        store.orgFollowerBands = ["Org B": .under1k]
        store.save()
        let good = StoreBackups.existing(for: file).count

        try "corrupt".write(to: file, atomically: true, encoding: .utf8)
        store.save()

        XCTAssertEqual(StoreBackups.existing(for: file).count, good,
                       "a corrupt file must never displace a good backup")
    }
}

/// #88: the failure has to outrank the empty state. Showing "no posts imported
/// yet" over a store that could not be read tells Dan to go and import, when
/// his existing import is sitting unreadable in a file beside the store.
final class InsightsDisplayTests: XCTestCase {

    func testAFailedLoadShowsTheFailureNotTheEmptyState() {
        let state = InsightsDisplay.state(recoveryMessage: "could not be read", postCount: 0)
        XCTAssertEqual(state, .failedToLoad("could not be read"))
    }

    func testAGenuinelyEmptyStoreShowsTheEmptyState() {
        XCTAssertEqual(InsightsDisplay.state(recoveryMessage: nil, postCount: 0), .empty)
    }

    func testAStoreWithPostsShowsTheData() {
        XCTAssertEqual(InsightsDisplay.state(recoveryMessage: nil, postCount: 12), .data)
    }

    func testAFailureStillShowsEvenWhenSomePostsLoaded() {
        // A partial read is still a read that went wrong; the count must not
        // be allowed to hide it.
        XCTAssertEqual(InsightsDisplay.state(recoveryMessage: "partial", postCount: 3),
                       .failedToLoad("partial"))
    }

    func testAnEmptyMessageIsNotAFailure() {
        XCTAssertEqual(InsightsDisplay.state(recoveryMessage: "", postCount: 0), .empty)
    }

    func testTheBannerShowsOnlyOnAFailure() {
        XCTAssertTrue(InsightsDisplay.showsRecoveryBanner(recoveryMessage: "x", postCount: 0))
        XCTAssertFalse(InsightsDisplay.showsRecoveryBanner(recoveryMessage: nil, postCount: 0))
        XCTAssertFalse(InsightsDisplay.showsRecoveryBanner(recoveryMessage: nil, postCount: 5))
    }
}
