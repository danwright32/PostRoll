import XCTest

/// #441 at the level Dan actually meets it: the alert that reports the loss has
/// to be able to undo it, and the events have to come back into the window.
///
/// Driven against a temp data root, so `loadStore`'s launch sweeps (which delete
/// media for every event NOT in the list they are handed) cannot reach a single
/// real photo (L2).
final class AppStateRestoreTests: XCTestCase {
    private var root: URL!
    private var store: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = root.appendingPathComponent("events.json")
    }

    override func tearDownWithError() throws {
        StoreSaveGate.shared.unblock(store)
        try? FileManager.default.removeItem(at: root)
    }

    private func anEvent(_ name: String) -> Event {
        Event(name: name, org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
    }

    private func write(_ events: [Event], backedUpAt minute: Int) throws {
        let when = Date(timeIntervalSince1970: TimeInterval(minute * 60))
        StoreBackups.rotate(store: store, isValid: EventStore.decodes, now: { when })
        try JSONEncoder().encode(events).write(to: store, options: .atomic)
    }

    @MainActor
    private func state() -> AppState {
        AppState(events: [], storeURL: store, dataRoot: root)
    }

    @MainActor
    func testACorruptStoreOffersTheBackupItCanPutBack() throws {
        let real = anEvent("The show I do not want to lose")
        try write([real], backedUpAt: 1)
        try write([real], backedUpAt: 2)
        try Data("not events".utf8).write(to: store)

        let app = state()
        app.loadStore()

        XCTAssertNotNil(app.dataLoadWarning, "the corruption was not reported at all")
        let offer = try XCTUnwrap(app.restorableBackup,
                                  "five good generations sit beside the bad file and nothing offers them")
        let warning = try XCTUnwrap(app.dataLoadWarning)
        XCTAssertTrue(warning.contains("can be put back"),
                      "the alert has a button whose consequence it never states: \(warning)")
        XCTAssertNotNil(offer.takenAt)
    }

    @MainActor
    func testPressingRestoreBringsTheEventsBackIntoTheWindow() throws {
        let real = anEvent("The show I do not want to lose")
        try write([real], backedUpAt: 1)
        try write([real], backedUpAt: 2)
        try Data("not events".utf8).write(to: store)

        let app = state()
        app.loadStore()
        XCTAssertTrue(app.events.isEmpty, "setup: the window should be empty here")

        let outcome = app.restoreLatestBackup()

        guard case .restored = outcome else { return XCTFail("restore reported \(outcome)") }
        XCTAssertEqual(app.events.map(\.id), [real.id])
        XCTAssertNil(app.dataLoadWarning, "the alert outlived the loss it was about")
        XCTAssertNil(app.restorableBackup)
    }

    @MainActor
    func testAHealthyStoreOffersNothing() throws {
        try write([anEvent("Show")], backedUpAt: 1)

        let app = state()
        app.loadStore()

        XCTAssertNil(app.dataLoadWarning)
        XCTAssertNil(app.restorableBackup, "an offer to restore over a store that read fine")
    }

    @MainActor
    func testACorruptStoreWithNoBackupSaysThereIsNothingToPutBack() throws {
        try Data("not events".utf8).write(to: store)

        let app = state()
        app.loadStore()

        XCTAssertNil(app.restorableBackup)
        // A button that cannot be offered still has to be accounted for in
        // words, rather than leaving a message that implies one exists (L109).
        let warning = try XCTUnwrap(app.dataLoadWarning)
        XCTAssertTrue(warning.contains("no earlier backup"), warning)
    }

    @MainActor
    func testAFailedRestoreSaysSoRatherThanLookingLikeItWorked() throws {
        try XCTSkipIf(getuid() == 0, "permission based tests are meaningless as root")
        let real = anEvent("Show")
        try write([real], backedUpAt: 1)
        try write([real], backedUpAt: 2)
        try Data("not events".utf8).write(to: store)

        let app = state()
        app.loadStore()
        XCTAssertNotNil(app.restorableBackup)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.path)
        }

        let outcome = app.restoreLatestBackup()

        guard case .failed = outcome else { return XCTFail("restore reported \(outcome)") }
        XCTAssertTrue(app.events.isEmpty, "events appeared from a restore that did not happen")
        let warning = try XCTUnwrap(app.dataLoadWarning)
        XCTAssertTrue(warning.contains("could not be put back"), warning)
    }
}
