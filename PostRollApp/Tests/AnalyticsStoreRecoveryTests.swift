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
        // The read-failure tests leave the file or its folder unreadable, so
        // access has to come back before the temp tree can be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Permission bits mean nothing to root, so these would pass by reading the
    /// file successfully and proving nothing.
    private func skipIfRoot() throws {
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode],
                                              ofItemAtPath: url.path)
    }

    private func setAsideCopies() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
    }

    @MainActor
    private func storeWithOnePost() throws -> Data {
        let store = AnalyticsStore(fileURL: file)
        store.orgFollowerBands = ["Org A": .under1k]
        store.save()
        return try Data(contentsOf: file)
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

    // MARK: - A read failure is not corruption (#439)
    //
    // EventStore and AccountBook both got this from #88; this store only got
    // half of it. analytics.json holds every imported Instagram post and report,
    // and rebuilding it means re-exporting from Meta.

    @MainActor
    func testAFileThatCouldNotBeReadIsNeverRenamedAsCorrupt() throws {
        try skipIfRoot()
        let original = try storeWithOnePost()
        try chmod(file, 0o000)

        let store = AnalyticsStore(fileURL: file)

        let message = try XCTUnwrap(store.recoveryMessage,
                                    "a denied file must not load as an empty history")
        XCTAssertFalse(message.contains("set aside"),
                       "nothing was set aside, so the message must not say so: \(message)")
        XCTAssertEqual(try setAsideCopies(), [],
                       "a file we could not READ must never be renamed as corrupt")
        try chmod(file, 0o644)
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "the bytes must be exactly where they were")
    }

    @MainActor
    func testADeniedFolderIsNotMistakenForAFreshInstall() throws {
        try skipIfRoot()
        _ = try storeWithOnePost()
        // The recorded trap: `fileExists` returns false for a path the process
        // is denied, so a TCC refusal used to read as a first launch. An empty
        // Insights screen then says "nothing imported yet" over a failure.
        try chmod(dir, 0o000)

        let store = AnalyticsStore(fileURL: file)

        let message = try XCTUnwrap(store.recoveryMessage,
                                    "a denied folder read as a fresh install")
        XCTAssertTrue(message.contains("could not be read"), message)
    }

    @MainActor
    func testSavingIsRefusedWhileTheFileCouldNotBeRead() throws {
        try skipIfRoot()
        let original = try storeWithOnePost()
        try chmod(file, 0o000)
        let store = AnalyticsStore(fileURL: file)
        XCTAssertNotNil(store.recoveryMessage)

        // Physically writable again, but still refused: what is in the file is
        // unknown, and the in-memory list is empty because the read failed. The
        // first save would write that emptiness over every imported post.
        try chmod(file, 0o644)
        store.orgFollowerBands = ["Org B": .under1k]

        XCTAssertEqual(store.save(), .blocked,
                       "the save has to report that it refused, not that it worked")
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "the unread file was overwritten by the next save")
    }

    @MainActor
    func testAFailedSetAsideAlsoBlocksSaving() throws {
        try skipIfRoot()
        try "definitely not analytics json".write(to: file, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: file)
        // Readable, undecodable, and unmovable: the file is still the only copy.
        try chmod(dir, 0o500)

        let store = AnalyticsStore(fileURL: file)
        XCTAssertNotNil(store.recoveryMessage)

        try chmod(dir, 0o755)
        store.orgFollowerBands = ["Org B": .under1k]

        XCTAssertEqual(store.save(), .blocked)
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "the only copy was eroded by a save it should have refused")
    }

    @MainActor
    func testACorruptFileThatWasSetAsideStaysSaveable() throws {
        // The other side of the gate. A corrupt file that WAS preserved is not a
        // reason to stop saving: refusing here would leave the app unable to
        // record anything until someone deleted a file by hand.
        try "not json".write(to: file, atomically: true, encoding: .utf8)

        let store = AnalyticsStore(fileURL: file)
        XCTAssertNotNil(store.recoveryMessage)
        store.orgFollowerBands = ["Org B": .under1k]
        XCTAssertEqual(store.save(), .saved,
                       "a preserved corrupt file is no reason to stop recording")

        let reloaded = AnalyticsStore(fileURL: file)
        XCTAssertEqual(reloaded.orgFollowerBands, ["Org B": .under1k])
        XCTAssertNil(reloaded.recoveryMessage)
    }

    @MainActor
    func testAReadFailureAndCorruptionGetDifferentMessages() throws {
        try skipIfRoot()
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        let corrupt = try XCTUnwrap(AnalyticsStore(fileURL: file).recoveryMessage)

        // Set the corrupt file aside, put a good one back, then deny it.
        _ = try storeWithOnePost()
        try chmod(file, 0o000)
        let unreadable = try XCTUnwrap(AnalyticsStore(fileURL: file).recoveryMessage)

        XCTAssertNotEqual(corrupt, unreadable,
                          "two different causes need two different messages (L11)")
        XCTAssertTrue(unreadable.contains("nothing new will be saved"),
                      "the read-failure message has to say saving has stopped: \(unreadable)")
        XCTAssertFalse(unreadable.contains(".."),
                       "the system's reason already ends in a stop: \(unreadable)")
    }

    @MainActor
    func testAMissingFileIsStillAFreshInstall() throws {
        let store = AnalyticsStore(fileURL: file)

        XCTAssertNil(store.recoveryMessage, "a first launch is not a failure")
        store.orgFollowerBands = ["Org A": .under1k]
        store.save()
        XCTAssertEqual(AnalyticsStore(fileURL: file).orgFollowerBands,
                       ["Org A": .under1k])
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
