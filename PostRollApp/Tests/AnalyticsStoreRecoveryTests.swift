import XCTest

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
