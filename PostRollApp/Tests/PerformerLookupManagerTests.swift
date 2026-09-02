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

    // MARK: - The lock names what it protects (#1049)

    /// `isBusy` was `Kind.allCases`, so every kind added to the enum was
    /// enrolled in the shared exclusion lock by default. Two independent review
    /// agents found the same thing while reading the account numbers plan: the
    /// automatic figures fetch added as a third kind would have disabled both
    /// buttons Dan did not press, for up to the 300 second deadline, and the
    /// guard is a bare `return`, so nothing on screen would connect the two.
    ///
    /// The defect is already here between the two existing kinds. Neither
    /// button is disabled while the OTHER lookup runs, so pressing one during
    /// the other did nothing at all and said nothing at all.

    func testEachKindDecidesForItselfWhetherItBlocksTheOthers() {
        // An exhaustive switch is the guard (L113). A new kind cannot compile
        // until somebody has answered this question for it, which is the whole
        // point: `Kind.allCases` answered it for them, and answered wrong.
        XCTAssertTrue(PerformerLookupManager.Kind.handles.contendsForThePerformerList)
        XCTAssertTrue(PerformerLookupManager.Kind.fromWeb.contendsForThePerformerList)
    }

    func testTheLockIsNotBuiltFromEveryCaseOfTheEnum() {
        // Derived from the SOURCE, not from behaviour. Both of today's kinds
        // contend, so `contendingKinds` and `Kind.allCases` hold the same two
        // values and no behavioural test can tell them apart: an assertion
        // comparing them would be comparing the implementation with itself.
        // This is the one that catches the default coming back, on the day it
        // lands rather than on the day a third kind is added.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent("Sources/Services/PerformerLookupManager.swift")
        let code = SwiftSourceText.withoutComments(
            try! String(contentsOf: source, encoding: .utf8))

        XCTAssertFalse(code.contains("Kind.allCases.contains"),
                       "the exclusion lock is back to covering every case of the enum, "
                       + "so a kind added later is enrolled in it without anybody "
                       + "deciding, which is what #1049 is about")
        XCTAssertTrue(code.contains("Self.contendingKinds.contains"),
                      "the lock does not read the per-kind answer at all")
    }

    func testARefusedLookupSaysWhichOneIsHoldingTheList() async throws {
        // The refusal was a bare `return` (L148): the control did nothing, said
        // nothing, and pressing it again was the only diagnosis available.
        let event = event(performers: [Performer(name: "Jenna Robison")])
        let state = state([event])
        let manager = PerformerLookupManager()
        let gate = Gate()
        manager.fetchFromWeb = { _ in
            await gate.held()
            return []
        }

        XCTAssertNil(manager.blockedReason(for: event.id),
                     "nothing is running, so nothing may claim the list is held")

        manager.startWebFetch(eventID: event.id, url: "https://example.com",
                              eventName: "Spring Gala", appState: state)

        let reason = try XCTUnwrap(manager.blockedReason(for: event.id))
        XCTAssertTrue(reason.contains("reading the event page"),
                      "the reason has to name the lookup that is actually running, "
                      + "or it cannot be acted on: \(reason)")

        gate.open()
        await until("the web fetch finished") { !manager.hasWorkInFlight }
        XCTAssertNil(manager.blockedReason(for: event.id),
                     "the run finished, so the reason must go with it")
    }

    func testTheReasonNamesTheOtherLookupToo() async throws {
        // The positive control for the message (L11): both kinds must produce
        // their own wording, or one sentence is answering for both and the
        // person is told the wrong thing about which control to wait for.
        let event = event(performers: [Performer(name: "Jenna Robison")])
        let state = state([event])
        let manager = PerformerLookupManager()
        let gate = Gate()
        manager.lookUpHandles = { _, _, _, _ in
            await gate.held()
            return []
        }

        manager.startHandleLookup(eventID: event.id, org: "Decoda", venue: "Merkin Hall",
                                  eventName: "Spring Gala", appState: state)

        let reason = try XCTUnwrap(manager.blockedReason(for: event.id))
        XCTAssertTrue(reason.contains("looking up handles"), reason)

        gate.open()
        await until("the handle lookup finished") { !manager.hasWorkInFlight }
    }

    func testTheButtonsAreUnavailableWithTheirReasonRatherThanSilent() {
        // The editor is handed the reason, so the control it disables can say
        // why. A disabled control with no reason beside it is the same silence
        // in a different shape (L54, L109).
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PostRollApp
            .appendingPathComponent("Sources/Views/OCRReviewView.swift")
        let code = SwiftSourceText.withoutComments(
            try! String(contentsOf: source, encoding: .utf8))

        XCTAssertTrue(code.contains("lookupManager.blockedReason(for: event.id)"),
                      "the performers editor is not told which lookup holds the list, "
                      + "so it cannot say why either button is unavailable")
        XCTAssertTrue(code.contains("let lookupBlockedReason: String?"),
                      "the editor does not take the reason at all")
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

    /// Holds an injected call open until the test lets it go (L290).
    ///
    /// The alternative, and what the older tests in this file do, is to sleep
    /// inside the seam for longer than the assertions take. That asserts about
    /// the machine's load rather than about the code, and it is slowest
    /// precisely when the machine is busiest, which is when it is judged.
    /// A run is in flight from the moment `begin` is called, synchronously,
    /// so nothing has to be waited for at all to observe one.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var opened = false

        func held() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    /// Wait for a condition rather than for a duration.
    ///
    /// Fails at the bound rather than returning, because a wait that gives up
    /// quietly reports a condition that never held as one that did (L98, L110).
    private func until(_ description: String, _ condition: () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("never became true: \(description)", file: file, line: line)
    }
}
