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
        try? FileManager.default.removeItem(at: dir)
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
