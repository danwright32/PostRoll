import XCTest

/// #446 on the real save path, not just the message text.
///
/// A message nobody sets is the same as no message, so these drive AppState's
/// actual edit methods against a store it cannot write to, and require the
/// failure to show up and then to clear itself once a save lands.
/// Not `@MainActor` on the class: Xcode 16.4, which CI runs, then rejects
/// `setUpWithError` touching these properties, because that override is
/// nonisolated and the local Xcode is the one that accepts it. Each test method
/// is isolated instead, the same way `AnalyticsStoreRecoveryTests` does it.
final class AppStateSaveFailureTests: XCTestCase {

    private var dir: URL!
    /// A FILE where the store's parent directory belongs, so every write fails.
    /// Chosen over permission bits because it behaves the same for root, which
    /// permission based tests do not.
    private var blocker: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        blocker = dir.appendingPathComponent("store")
        try Data("not a directory".utf8).write(to: blocker)
        storeURL = blocker.appendingPathComponent("events.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func anEvent(_ name: String) -> Event {
        Event(name: name, org: "Org", venue: "Hall", date: Date(), shootType: .fullShow)
    }

    /// Turns the blocking file into a real directory, so the next save works.
    private func unblock() throws {
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
    }

    @MainActor
    func testAFailedSaveIsSurfacedRatherThanLogged() throws {
        let state = AppState(events: [], storeURL: storeURL, dataRoot: dir)

        state.addEvent(anEvent("Show"))

        let failure = try XCTUnwrap(state.saveFailure,
                                    "the save failed and nothing on screen says so")
        XCTAssertTrue(failure.contains("not been saved"), failure)
    }

    @MainActor
    func testTheFailureStaysUntilASaveActuallySucceeds() throws {
        let state = AppState(events: [], storeURL: storeURL, dataRoot: dir)
        state.addEvent(anEvent("Show"))
        XCTAssertNotNil(state.saveFailure)

        // A second failing edit must not clear it either.
        state.addEvent(anEvent("Second"))
        XCTAssertNotNil(state.saveFailure, "a further failure cleared the warning")

        try unblock()
        state.addEvent(anEvent("Third"))

        XCTAssertNil(state.saveFailure, "the warning outlived the failure it was about")
    }

    @MainActor
    func testADebouncedTextEditReportsItsFailureToo() throws {
        // The path this issue is really about: typing a caption for an evening.
        // The debounced writer used to be the one save whose outcome could not
        // reach anything at all.
        let event = anEvent("Show")
        let state = AppState(events: [event], storeURL: storeURL, dataRoot: dir)

        // Which field is edited does not matter here; the debounced PATH does.
        // That is the one the caption and blog editors use on every keystroke.
        var edited = event
        edited.name = "Show, with a title I do not want to lose"
        state.updateEventDebounced(edited)
        state.flushPendingWrites()

        XCTAssertNotNil(state.saveFailure,
                        "an evening of typing can fail with nothing said about it")
    }

    @MainActor
    func testAWorkingStoreSaysNothing() throws {
        try unblock()
        let state = AppState(events: [], storeURL: storeURL, dataRoot: dir)

        state.addEvent(anEvent("Show"))

        XCTAssertNil(state.saveFailure, "a working save must not raise a warning")
    }
}
