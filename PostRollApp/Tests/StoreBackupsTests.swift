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
