import XCTest

/// #441: five verified-good generations of events.json sat beside a corrupt
/// store with nothing in the app able to put one back, and ordinary use ate all
/// five within five saves.
///
/// These drive the real files, because every claim here is about what is on
/// disk after a sequence of saves, and a stubbed filesystem would agree with
/// whatever this code believes about itself.
final class StoreRestoreTests: XCTestCase {
    private var dir: URL!
    private var store: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreRestoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = dir.appendingPathComponent("events.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func anEvent(_ name: String) -> Event {
        Event(name: name, org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
    }

    /// Backups are stamped to the second, so real saves inside one test run
    /// would collide and be distinguished only by the `-1` suffix. Writing the
    /// store and rotating with an injected clock gives each generation its own
    /// stamp, which is what the ordering and the cutoff comparison rely on.
    @discardableResult
    private func saveGeneration(_ events: [Event], at minute: Int) throws -> URL {
        let when = Date(timeIntervalSince1970: TimeInterval(minute * 60))
        StoreBackups.rotate(store: store, isValid: EventStore.decodes, now: { when })
        try JSONEncoder().encode(events).write(to: store, options: .atomic)
        return store
    }

    /// Corrupt the store and let a load find it, at a chosen moment on the same
    /// clock the generations use. Real corruption naturally falls between the
    /// good generations and everything saved afterwards, and the protection
    /// rule keys on exactly that ordering.
    private func corrupt(at minute: Int) throws {
        try Data("not events".utf8).write(to: store)
        _ = EventStore.load(from: store,
                            now: { Date(timeIntervalSince1970: TimeInterval(minute * 60)) })
    }

    private func backupNames() -> [String] {
        StoreBackups.existing(for: store).map(\.lastPathComponent)
    }

    // MARK: - Which backup a restore offers

    func testTheOfferedBackupPredatesTheCorruption() throws {
        let real = anEvent("The show I do not want to lose")
        try saveGeneration([real], at: 1)
        try saveGeneration([real], at: 2)
        let goodGenerations = backupNames()
        XCTAssertFalse(goodGenerations.isEmpty, "no backup was taken, so nothing else here means anything")

        // The store goes bad and is set aside, then the app runs on empty and
        // saves, which rotates a perfectly valid backup of the emptiness.
        try corrupt(at: 5)
        // Two saves, not one: the load moved the store aside, so the first save
        // has nothing to copy and the emptiness only reaches the backup ring on
        // the second. One save here would leave the newest backup good and this
        // test would pass without the rule it is about.
        try saveGeneration([], at: 10)
        try saveGeneration([], at: 11)
        XCTAssertNotEqual(StoreBackups.newest(for: store)?.lastPathComponent,
                          goodGenerations.last,
                          "setup: the newest backup should be a copy of the empty store")

        let offered = try XCTUnwrap(StoreBackups.restorable(for: store))
        XCTAssertTrue(goodGenerations.contains(offered.lastPathComponent),
                      "the restore offers \(offered.lastPathComponent), a copy of the empty store")
    }

    func testWithNoCorruptionTheOfferIsSimplyTheNewestBackup() throws {
        try saveGeneration([anEvent("One")], at: 1)
        try saveGeneration([anEvent("Two")], at: 2)
        XCTAssertEqual(StoreBackups.restorable(for: store), StoreBackups.newest(for: store))
    }

    // MARK: - The generations survive ordinary use

    func testPreCorruptionBackupsAreNotPrunedAwayByLaterSaves() throws {
        let real = anEvent("Show")
        // Six saves, five backups: the first save has nothing to copy, because
        // the store does not exist yet.
        for minute in 1...6 { try saveGeneration([real], at: minute) }
        let goodGenerations = Set(backupNames())
        XCTAssertEqual(goodGenerations.count, 5, "expected the full ring before the corruption")

        try corrupt(at: 7)

        // Far more saves than the ring holds. Every one of them rotates a copy
        // of the near-empty store, which is what used to push the real ones out.
        for minute in 20...40 { try saveGeneration([], at: minute) }

        let survivors = Set(backupNames())
        XCTAssertTrue(goodGenerations.isSubset(of: survivors),
                      "lost \(goodGenerations.subtracting(survivors)) to ordinary saves")
    }

    func testOrdinaryPruningStillCapsTheRingWhenNothingWentWrong() throws {
        for minute in 1...9 { try saveGeneration([anEvent("Show")], at: minute) }
        XCTAssertEqual(backupNames().count, StoreBackups.defaultKeep,
                       "with no corruption the ring must still be bounded")
    }

    // MARK: - The restore itself

    func testRestorePutsTheEventsBack() throws {
        let real = anEvent("The show I do not want to lose")
        try saveGeneration([real], at: 1)
        try saveGeneration([real], at: 2)

        try corrupt(at: 5)
        try saveGeneration([], at: 10)
        try saveGeneration([], at: 11)
        XCTAssertTrue(EventStore.load(from: store).events.isEmpty, "setup: the store should be empty here")

        let outcome = StoreBackups.restore(store: store, isValid: EventStore.decodes)

        guard case .restored = outcome else {
            return XCTFail("restore reported \(outcome)")
        }
        XCTAssertEqual(EventStore.load(from: store).events.map(\.id), [real.id])
    }

    func testRestoreKeepsWhateverItReplaced() throws {
        let real = anEvent("Show")
        try saveGeneration([real], at: 1)
        try saveGeneration([real], at: 2)
        try corrupt(at: 5)
        let sinceTheCorruption = anEvent("Entered after the corruption")
        try saveGeneration([sinceTheCorruption], at: 10)

        _ = StoreBackups.restore(store: store, isValid: EventStore.decodes)

        // Work entered into the empty store is not the app's to throw away
        // because a restore was asked for (L5).
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".replaced-") }
        XCTAssertEqual(kept.count, 1, "the replaced store was deleted rather than kept: \(kept)")
        let keptURL = dir.appendingPathComponent(try XCTUnwrap(kept.first))
        let inside = try JSONDecoder().decode([Event].self, from: Data(contentsOf: keptURL))
        XCTAssertEqual(inside.map(\.id), [sinceTheCorruption.id])
    }

    // MARK: - Failure paths

    func testABackupThatDoesNotDecodeIsRefusedRatherThanRestored() throws {
        let real = anEvent("Show")
        try saveGeneration([real], at: 1)
        try saveGeneration([real], at: 2)
        // A backup that went bad on disk after it was taken. Restoring it would
        // replace one unreadable file with another and report success.
        let backup = try XCTUnwrap(StoreBackups.newest(for: store))
        try Data("rot".utf8).write(to: backup)

        let outcome = StoreBackups.restore(store: store, isValid: EventStore.decodes)

        guard case .failed = outcome else {
            return XCTFail("a backup that does not decode was accepted: \(outcome)")
        }
        XCTAssertEqual(EventStore.load(from: store).events.map(\.id), [real.id],
                       "the store was disturbed by a restore that could not go ahead")
    }

    func testNoBackupIsItsOwnAnswerNotAFailure() {
        XCTAssertEqual(StoreBackups.restore(store: store, isValid: EventStore.decodes),
                       .noBackup)
    }

    func testAnUnwritableStoreReportsFailureRatherThanClaimingARestore() throws {
        // Permission bits mean nothing to root, which would load the file
        // happily and pass this test for the wrong reason.
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
        let real = anEvent("Show")
        try saveGeneration([real], at: 1)
        try saveGeneration([real], at: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
        }

        let outcome = StoreBackups.restore(store: store, isValid: EventStore.decodes)

        guard case .failed = outcome else {
            return XCTFail("a restore that could not write reported \(outcome)")
        }
    }

    // MARK: - The two stamps have to be comparable

    func testTheCorruptStampAndTheBackupStampShareOneClock() throws {
        // The protection above compares a `.corrupt-` name against `.bak` names.
        // Two formatters in different zones make that comparison quietly wrong
        // for several hours a day, and nothing about reading either file would
        // show it (L39).
        let noon = Date(timeIntervalSince1970: 1_754_000_000)
        try Data("{}".utf8).write(to: store)
        let setAside = try XCTUnwrap(StoreRecovery.setAside(store, now: { noon }))

        let expected = StoreBackups.stamp.string(from: noon)
        XCTAssertTrue(setAside.lastPathComponent.hasSuffix(expected),
                      "\(setAside.lastPathComponent) does not carry the shared stamp \(expected)")
    }

    func testTheOfferCanBeDatedForTheAlert() throws {
        try saveGeneration([anEvent("Show")], at: 1)
        try saveGeneration([anEvent("Show")], at: 2)
        let backup = try XCTUnwrap(StoreBackups.restorable(for: store))
        XCTAssertEqual(StoreBackups.takenAt(backup, of: store),
                       Date(timeIntervalSince1970: 120))
    }
}
