import XCTest

/// Pins the store recovery contract (issues #2 and #25): an undecodable
/// events.json must be set aside, never silently treated as empty (the next
/// save would overwrite it and destroy every event), and each save keeps
/// the previous generation as .bak.
final class EventStoreTests: XCTestCase {
    private var dir: URL!
    private var store: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = dir.appendingPathComponent("events.json")
    }

    override func tearDownWithError() throws {
        // Permission based tests leave the file or its directory unreadable;
        // restore access so the temp tree can actually be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Permission bits mean nothing to root, so the read-failure tests would
    /// silently pass by loading the file successfully.
    private func skipIfRoot() throws {
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
    }

    private func writeValidStore() throws -> Event {
        let event = Event(name: "Show", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        EventStore.save([event], to: store)
        return event
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func corruptBackups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
    }

    func testMissingFileLoadsEmptyWithNoWarning() {
        let result = EventStore.load(from: store)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNil(result.recoveryMessage)
    }

    func testSaveLoadRoundTrip() {
        let event = Event(name: "Show", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        EventStore.save([event], to: store)
        let result = EventStore.load(from: store)
        XCTAssertEqual(result.events.map(\.id), [event.id])
        XCTAssertNil(result.recoveryMessage)
    }

    func testCorruptFileIsSetAsideNotWiped() throws {
        try Data("definitely not json".utf8).write(to: store)

        let result = EventStore.load(from: store)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNotNil(result.recoveryMessage, "decode failure must be surfaced")
        // The unreadable file was moved aside, so a following save cannot
        // destroy it...
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        let backups = try corruptBackups()
        XCTAssertEqual(backups.count, 1)
        let preserved = dir.appendingPathComponent(backups[0])
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "definitely not json")

        // ...and saving afterwards leaves the set aside copy intact.
        EventStore.save([], to: store)
        XCTAssertEqual(try corruptBackups().count, 1)
    }

    func testSaveRotatesBackupGeneration() throws {
        let first = Event(name: "First", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        let second = Event(name: "Second", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        EventStore.save([first], to: store)
        EventStore.save([second], to: store)

        let backup = store.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let previous = try JSONDecoder().decode([Event].self, from: Data(contentsOf: backup))
        XCTAssertEqual(previous.map(\.name), ["First"])
        let current = EventStore.load(from: store)
        XCTAssertEqual(current.events.map(\.name), ["Second"])
    }

    // MARK: - Read failure is not corruption (issue #74)

    func testUnreadableFileIsNeitherSetAsideNorCalledCorrupt() throws {
        try skipIfRoot()
        _ = try writeValidStore()
        let original = try Data(contentsOf: store)
        try chmod(store, 0o000)

        let result = EventStore.load(from: store)

        XCTAssertEqual(result.status, .unreadable, "a read failure is not a decode failure")
        XCTAssertFalse(result.isAuthoritative, "an unreadable store must not pass as the real event list")
        XCTAssertNotNil(result.recoveryMessage, "the user has to be told the store could not be read")
        // The file itself must be exactly where it was, untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        XCTAssertEqual(try corruptBackups(), [], "a read failure must never rename the store")
        try chmod(store, 0o644)
        XCTAssertEqual(try Data(contentsOf: store), original)
    }

    func testSaveIsRefusedWhileTheStoreIsUnreadable() throws {
        try skipIfRoot()
        _ = try writeValidStore()
        let original = try Data(contentsOf: store)
        try chmod(store, 0o000)

        XCTAssertEqual(EventStore.load(from: store).status, .unreadable)
        // Even once the file is physically writable again, saving stays blocked
        // until a load proves the store can be read: otherwise the first edit
        // writes an empty list over every event.
        try chmod(store, 0o644)
        let outcome = EventStore.save([], to: store)

        XCTAssertEqual(outcome, .blocked)
        XCTAssertEqual(try Data(contentsOf: store), original, "the intact store must survive the blocked save")
    }

    func testSuccessfulReloadUnblocksSaving() throws {
        try skipIfRoot()
        let event = try writeValidStore()
        try chmod(store, 0o000)
        XCTAssertEqual(EventStore.load(from: store).status, .unreadable)
        try chmod(store, 0o644)

        let reloaded = EventStore.load(from: store)
        XCTAssertEqual(reloaded.status, .ok)
        XCTAssertEqual(reloaded.events.map(\.id), [event.id])

        let second = Event(name: "Second", org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
        XCTAssertEqual(EventStore.save([event, second], to: store), .saved)
        XCTAssertEqual(EventStore.load(from: store).events.map(\.name), ["Show", "Second"])
    }

    func testSetAsideFailureBlocksSavesAndLeavesTheFileInPlace() throws {
        try skipIfRoot()
        try Data("definitely not json".utf8).write(to: store)
        // A read only directory: the file still reads and still fails to decode,
        // but it cannot be moved aside.
        try chmod(dir, 0o500)

        let result = EventStore.load(from: store)

        XCTAssertEqual(result.status, .corrupt(setAsideAs: nil), "the set aside did not happen")
        XCTAssertFalse(result.isAuthoritative)
        XCTAssertNotNil(result.recoveryMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))

        // Saving would erode the only copy of the real data, so it is refused
        // even after the directory becomes writable again.
        try chmod(dir, 0o755)
        XCTAssertEqual(EventStore.save([], to: store), .blocked)
        XCTAssertEqual(try String(contentsOf: store, encoding: .utf8), "definitely not json")
    }

    func testCorruptStoreThatWasSetAsideStaysSaveable() throws {
        try Data("definitely not json".utf8).write(to: store)

        let result = EventStore.load(from: store)

        guard case .corrupt(let name) = result.status else {
            return XCTFail("expected a corrupt status, got \(result.status)")
        }
        XCTAssertNotNil(name, "the file was moved aside, so its name is known")
        XCTAssertFalse(result.isAuthoritative)
        // The original is preserved under a new name, so starting fresh is safe.
        XCTAssertEqual(EventStore.save([], to: store), .saved)
    }

    func testMissingFileIsNotTreatedAsAReadFailure() {
        let result = EventStore.load(from: dir.appendingPathComponent("nothing-here.json"))

        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.isAuthoritative, "a first launch has an authoritative empty list")
    }

    func testStoreRecoverySetAsideMovesFile() throws {
        let file = dir.appendingPathComponent("some_store.json")
        try Data("broken".utf8).write(to: file)

        let backup = StoreRecovery.setAside(file)

        XCTAssertNotNil(backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup!.path))
        XCTAssertTrue(backup!.lastPathComponent.contains("corrupt-"))
    }
}
