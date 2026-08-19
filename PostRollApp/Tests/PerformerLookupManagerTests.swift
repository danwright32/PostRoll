import XCTest

/// The two performer lookups outlive the section that starts them (#707).
///
/// The same defect #693 fixed for the programme notes search, on the two calls
/// that issue flagged and did not touch: looking up handles, and reading the
/// performers off the event's website. Both kept their progress, their clock
/// and their error in the performers editor, which the accordion destroys the
/// moment another section is opened, and both wrote their results through a
/// binding that goes away when the screen is replaced.
///
/// Every test here is one of those two moments, and most are failure paths,
/// because a happy path test cannot tell a run that reported nothing from one
/// that never happened.
@MainActor
final class PerformerLookupManagerTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PerformerLookup-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func event(performers: [Performer]) -> Event {
        var event = Event(name: "Spring Gala", org: "Decoda", venue: "Merkin Hall",
                          date: Date(), shootType: .fullShow)
        event.stage = .ocrDone
        event.ocrResult = OCRResult(performers: performers)
        return event
    }

    private func state(_ events: [Event]) -> AppState {
        AppState(events: events,
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    nonisolated private static func suggestion(_ name: String, _ handle: String?)
        -> PythonBridge.HandleSuggestion {
        PythonBridge.HandleSuggestion(name: name, handle: handle,
                                      profileURL: nil, confidence: "high", note: nil)
    }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Handles

    func testASuggestionSurvivesTheSectionBeingClosed() async throws {
        // Nothing here renders anything, which is the state the app is in the
        // moment Dan opens another section. The suggestions are the run's
        // result and he accepts them one at a time, so they have to still be
        // there when he comes back.
        let event = event(performers: [Performer(name: "Jenna Robison")])
        let state = state([event])
        let manager = PerformerLookupManager()
        manager.lookUpHandles = { _, _, _, _ in [Self.suggestion("Jenna Robison", "@jenna")] }

        manager.startHandleLookup(eventID: event.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Spring Gala", appState: state)
        await settle()

        XCTAssertEqual(manager.suggestions(for: event.id).count, 1,
                       "the suggestions died with the editor that asked for them")
        XCTAssertFalse(manager.isRunning(.handles, for: event.id))
    }

    func testApplyingASuggestionWritesToTheEventRatherThanAScreen() async throws {
        let event = event(performers: [Performer(name: "Jenna Robison")])
        let state = state([event])
        let manager = PerformerLookupManager()

        manager.apply(Self.suggestion("Jenna Robison", "@jenna"), to: event.id, in: state)

        XCTAssertEqual(state.events.first?.ocrResult?.performers.first?.handle, "@jenna")
    }

    func testASuggestionForSomebodyNoLongerInTheListIsDroppedQuietly() async throws {
        // The list can be edited while the search runs, and it takes minutes.
        let event = event(performers: [Performer(name: "Somebody Else")])
        let state = state([event])
        let manager = PerformerLookupManager()

        manager.apply(Self.suggestion("Jenna Robison", "@jenna"), to: event.id, in: state)

        XCTAssertEqual(state.events.first?.ocrResult?.performers.first?.handle, "")
    }

    func testAHandleAlreadyFilledInIsNotOverwritten() async throws {
        // A handle Dan typed while waiting is his. The lookup exists to save
        // him the typing, not to undo it.
        let event = event(performers: [Performer(name: "Jenna Robison", handle: "@typed")])
        let state = state([event])
        let manager = PerformerLookupManager()

        manager.apply(Self.suggestion("Jenna Robison", "@fromweb"), to: event.id, in: state)

        XCTAssertEqual(state.events.first?.ocrResult?.performers.first?.handle, "@typed")
    }

    func testAFailedLookupKeepsItsReasonForTheReopenedSection() async throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "The handle search was refused" }
        }
        let event = event(performers: [Performer(name: "Jenna Robison")])
        let state = state([event])
        let manager = PerformerLookupManager()
        manager.lookUpHandles = { _, _, _, _ in throw Refused() }

        manager.startHandleLookup(eventID: event.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Spring Gala", appState: state)
        await settle()

        XCTAssertEqual(manager.failure(.handles, for: event.id),
                       "The handle search was refused")
    }

    func testAStalledHandleLookupBecomesAnError() async throws {
        let event = event(performers: [Performer(name: "Jenna Robison")])
        let state = state([event])
        let manager = PerformerLookupManager()
        manager.deadlineForTesting = 0.2
        manager.lookUpHandles = { _, _, _, _ in
            try await Task.sleep(for: .seconds(3600))
            return []
        }

        manager.startHandleLookup(eventID: event.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Spring Gala", appState: state)
        await settle()

        let failure = try XCTUnwrap(manager.failure(.handles, for: event.id))
        XCTAssertTrue(failure.lowercased().contains("did not come back"), failure)
        XCTAssertFalse(manager.isRunning(.handles, for: event.id))
    }

    // MARK: - Reading the event page

    func testWebPerformersLandOnTheEventWithNoScreenWatching() async throws {
        let event = event(performers: [Performer(name: "Old Name")])
        let state = state([event])
        let manager = PerformerLookupManager()
        manager.fetchFromWeb = { _ in [Performer(name: "From The Website")] }

        manager.startWebFetch(eventID: event.id, url: "https://example.com",
                              eventName: "Spring Gala", appState: state)
        await settle()

        XCTAssertEqual(state.events.first?.ocrResult?.performers.map(\.name),
                       ["From The Website"],
                       "the fetch completed into nothing, so the cast list it "
                       + "read was lost rather than merely unreported")
    }

    func testTheUndoSurvivesTheScreenThatOfferedIt() async throws {
        // The list it replaced is the only copy of what was there. An undo
        // whose input died with the view is not an undo (L97).
        let event = event(performers: [Performer(name: "Typed By Hand")])
        let state = state([event])
        let manager = PerformerLookupManager()
        manager.fetchFromWeb = { _ in [Performer(name: "From The Website")] }

        manager.startWebFetch(eventID: event.id, url: "https://example.com",
                              eventName: "Spring Gala", appState: state)
        await settle()
        manager.undoWebFetch(for: event.id, in: state)

        XCTAssertEqual(state.events.first?.ocrResult?.performers.map(\.name),
                       ["Typed By Hand"])
    }

    func testAFailedWebFetchLeavesTheListAlone() async throws {
        struct Refused: Error {}
        let event = event(performers: [Performer(name: "Typed By Hand")])
        let state = state([event])
        let manager = PerformerLookupManager()
        manager.fetchFromWeb = { _ in throw Refused() }

        manager.startWebFetch(eventID: event.id, url: "https://example.com",
                              eventName: "Spring Gala", appState: state)
        await settle()

        XCTAssertEqual(state.events.first?.ocrResult?.performers.map(\.name),
                       ["Typed By Hand"])
        XCTAssertNotNil(manager.failure(.fromWeb, for: event.id))
    }

    // MARK: - They cannot run over each other

    func testAWebFetchIsRefusedWhileHandlesAreBeingLookedUp() async throws {
        // The fetch REPLACES the list the handle lookup is filling in. Running
        // both would have one write over the other's result, and which won
        // would depend on which model call came back first.
        let event = event(performers: [Performer(name: "Jenna Robison")])
        let state = state([event])
        let manager = PerformerLookupManager()
        manager.lookUpHandles = { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(300))
            return []
        }
        let fetched = Counter()
        manager.fetchFromWeb = { _ in
            fetched.bump()
            return [Performer(name: "From The Website")]
        }

        manager.startHandleLookup(eventID: event.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Spring Gala", appState: state)
        manager.startWebFetch(eventID: event.id, url: "https://example.com",
                              eventName: "Spring Gala", appState: state)
        await settle()

        XCTAssertEqual(fetched.value, 0, "the web fetch ran over the handle lookup")
    }

    func testASecondHandleLookupIsNotStackedOnTheFirst() async throws {
        let event = event(performers: [Performer(name: "Jenna Robison")])
        let state = state([event])
        let manager = PerformerLookupManager()
        let started = Counter()
        manager.lookUpHandles = { _, _, _, _ in
            started.bump()
            try await Task.sleep(for: .milliseconds(300))
            return []
        }

        manager.startHandleLookup(eventID: event.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Spring Gala", appState: state)
        manager.startHandleLookup(eventID: event.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Spring Gala", appState: state)
        await settle()

        XCTAssertEqual(started.value, 1)
    }

    func testTwoEventsCanBeLookedUpAtOnce() async throws {
        // The control for the two refusals above: a guard that refused whatever
        // the state would satisfy them both while breaking the feature (L159).
        let first = event(performers: [Performer(name: "Jenna Robison")])
        var second = event(performers: [Performer(name: "Someone Else")])
        second.id = UUID()
        let state = state([first, second])
        let manager = PerformerLookupManager()
        let started = Counter()
        manager.lookUpHandles = { _, _, _, _ in
            started.bump()
            try await Task.sleep(for: .milliseconds(200))
            return []
        }

        manager.startHandleLookup(eventID: first.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Spring Gala", appState: state)
        manager.startHandleLookup(eventID: second.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Other", appState: state)
        await settle()

        XCTAssertEqual(started.value, 2,
                       "one event's lookup blocked another event's, so working "
                       + "on two shows at once means waiting for the first")
    }

    // MARK: - Wired into the screen

    func testTheEditorReadsBothRunsFromTheManager() throws {
        // All of the above can be right while the editor still keeps its own
        // copy, which is the defect: what Dan sees would go on being destroyed
        // by the collapse (L3).
        let code = try Self.reviewSource()

        for read in ["lookupManager.isRunning(.handles, for: event.id)",
                     "lookupManager.isRunning(.fromWeb, for: event.id)",
                     "lookupManager.suggestions(for: event.id)",
                     "lookupManager.failure(.handles, for: event.id)",
                     "lookupManager.failure(.fromWeb, for: event.id)"] {
            XCTAssertTrue(code.contains(read),
                          "the screen does not read \(read) from the manager, so "
                          + "that part of the run still dies with the section")
        }
        for held in ["@State private var isLookingUpHandles",
                     "@State private var isFetchingFromWeb",
                     "@State private var handleSuggestions"] {
            XCTAssertFalse(code.contains(held),
                           "the editor still holds \(held) itself")
        }
    }

    func testTheUndoGoesThroughTheManagerToo() throws {
        let code = try Self.reviewSource()
        XCTAssertTrue(code.contains("lookupManager.undoWebFetch(for: event.id"),
                      "the undo still reverses to a list held by the view, which "
                      + "is gone by the time it is needed")
    }

    nonisolated private static func reviewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/OCRReviewView.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
