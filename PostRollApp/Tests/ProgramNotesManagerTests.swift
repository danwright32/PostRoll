import XCTest

/// The programme notes search survives the screen that started it (#693).
///
/// Dan pressed "Fetch missing notes from web", opened the Scenes section while
/// it ran, and the search appeared to have died: the indicator was gone and
/// nothing said whether it was still running, finished, or failed.
///
/// The review screen is an accordion, so opening one section collapses another,
/// and the collapse destroyed the view holding the progress, the clock and the
/// error message. Switching events is the worse case: the whole screen remounts
/// and the binding the results were written through goes with it, so the run
/// completed into nothing and the notes were lost rather than merely
/// unreported.
///
/// Every test here is one of those two situations, and most of them are failure
/// paths, because a happy path test could not tell any of this apart.
@MainActor
final class ProgramNotesManagerTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProgramNotes-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func event(withNotes notes: String = "") -> Event {
        var event = Event(name: "Spring Gala", org: "Decoda", venue: "Merkin Hall",
                          date: Date(), shootType: .fullShow)
        event.stage = .ocrDone
        event.ocrResult = OCRResult(pieces: [
            Piece(composer: "Beethoven", title: "Symphony No. 5", notes: notes),
        ])
        return event
    }

    private func state(_ events: [Event]) -> AppState {
        AppState(events: events,
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    /// Static and nonisolated, so the fetch stubs below can build one without
    /// reaching back into this test case from another actor.
    nonisolated private static func result(_ notes: String?) -> PythonBridge.PieceNoteResult {
        PythonBridge.PieceNoteResult(title: "Symphony No. 5",
                                     composer: "Beethoven", notes: notes)
    }

    /// A manager whose search is this test rather than a paid model call.
    private func manager(
        _ fetch: @escaping @Sendable ([Piece], String, String) async throws
            -> [PythonBridge.PieceNoteResult]
    ) -> ProgramNotesManager {
        let manager = ProgramNotesManager()
        manager.fetchNotes = fetch
        return manager
    }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - It lands wherever Dan happens to be

    func testNotesLandOnTheEventEvenWithNoScreenWatching() async throws {
        // The whole point. Nothing in this test renders anything, which is the
        // state the app is in the moment Dan opens another section or another
        // event.
        let event = event()
        let state = state([event])
        let manager = manager { _, _, _ in [Self.result("Written in 1808.")] }

        manager.start(eventID: event.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        await settle()

        XCTAssertEqual(state.events.first?.ocrResult?.pieces.first?.notes,
                       "Written in 1808.",
                       "the search finished into nothing, so the notes it found "
                       + "were lost rather than merely unreported")
    }

    func testNotesLandOnTheEventTheSearchWasStartedFor() async throws {
        // The event switch case. The results must reach the event they are
        // about, not whichever one happens to be selected when they arrive.
        let first = event()
        var second = Event(name: "Other", org: "Other", venue: "Hall",
                           date: Date(), shootType: .fullShow)
        second.ocrResult = OCRResult(pieces: [Piece(composer: "Ravel", title: "Bolero")])
        let state = state([first, second])
        let manager = manager { _, _, _ in [Self.result("Written in 1808.")] }

        manager.start(eventID: first.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        state.selectedEventID = second.id      // Dan moves on while it runs
        await settle()

        XCTAssertEqual(state.events.first(where: { $0.id == first.id })?
            .ocrResult?.pieces.first?.notes, "Written in 1808.")
        XCTAssertEqual(state.events.first(where: { $0.id == second.id })?
            .ocrResult?.pieces.first?.notes, "",
                       "the notes landed on the event that happened to be open "
                       + "rather than the one they are about")
    }

    // MARK: - A failure is still there when he comes back

    func testAFailureIsKeptForTheSectionToShowWhenItReopens() async throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "The web search was refused" }
        }
        let event = event()
        let state = state([event])
        let manager = manager { _, _, _ in throw Refused() }

        manager.start(eventID: event.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        await settle()

        XCTAssertEqual(manager.failure(for: event.id), "The web search was refused",
                       "the reason died with the section that was closed when it "
                       + "arrived, so reopening it shows an idle button and no "
                       + "explanation")
        XCTAssertFalse(manager.isRunning(event.id))
    }

    func testAStalledSearchBecomesSomethingToActOnRatherThanAnIndicatorForever() async throws {
        // A wait with no deadline cannot fail, it can only hang, and a hang is
        // indistinguishable from slowness (L110).
        let event = event()
        let state = state([event])
        let manager = manager { _, _, _ in
            try await Task.sleep(for: .seconds(3600))
            return []
        }
        manager.deadlineForTesting = 0.2

        manager.start(eventID: event.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        await settle()

        let failure = try XCTUnwrap(manager.failure(for: event.id))
        XCTAssertTrue(failure.lowercased().contains("did not come back"), failure)
        XCTAssertFalse(manager.isRunning(event.id),
                       "the search is still shown as running long after its "
                       + "deadline passed")
    }

    func testAFailedSearchChangesNothingOnTheEvent() async throws {
        struct Refused: Error {}
        let event = event(withNotes: "Dan wrote this himself.")
        let state = state([event])
        let manager = manager { _, _, _ in throw Refused() }

        manager.start(eventID: event.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        await settle()

        XCTAssertEqual(state.events.first?.ocrResult?.pieces.first?.notes,
                       "Dan wrote this himself.")
    }

    // MARK: - It cannot be started twice

    func testASecondSearchIsNotStackedOnTheFirst() async throws {
        // Reopening the section mid run used to show the idle button again, so
        // a second search was one click away.
        let event = event()
        let state = state([event])
        let started = Counter()
        let manager = manager { _, _, _ in
            started.bump()
            try await Task.sleep(for: .milliseconds(300))
            return [Self.result("Written in 1808.")]
        }

        manager.start(eventID: event.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        manager.start(eventID: event.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        await settle()

        XCTAssertEqual(started.value, 1, "two searches ran for one event")
    }

    func testAnEventWhoseWorksAllHaveNotesStartsNothing() async {
        // Nothing to look for is not a run. A run with nothing in it would show
        // an indicator, take a deadline, and end in a merge of nothing.
        let event = event(withNotes: "Already written.")
        let state = state([event])
        let started = Counter()
        let manager = manager { _, _, _ in started.bump(); return [] }

        manager.start(eventID: event.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        await settle()

        XCTAssertEqual(started.value, 0)
        XCTAssertFalse(manager.isRunning(event.id))
    }

    // MARK: - What it writes, and what it leaves alone

    func testANoteTypedWhileTheSearchRanIsNotOverwritten() async throws {
        // The search was asked to save Dan the typing. Writing over what he
        // typed while waiting would be it destroying the work it exists to do.
        let event = event()
        let state = state([event])
        let manager = manager { _, _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return [Self.result("From the web.")]
        }

        manager.start(eventID: event.id, org: "Decoda", eventName: "Spring Gala",
                      appState: state)
        var live = try XCTUnwrap(state.events.first)
        live.ocrResult?.pieces[0].notes = "Dan typed this while waiting."
        state.updateEvent(live)
        await settle()

        XCTAssertEqual(state.events.first?.ocrResult?.pieces.first?.notes,
                       "Dan typed this while waiting.")
    }

    func testAResultForAWorkThatIsNoLongerThereIsDroppedQuietly() {
        // Matched by title and composer rather than by position, because the
        // list can be edited while the search runs.
        var pieces = [Piece(composer: "Beethoven", title: "Symphony No. 5")]
        let changed = ProgramNotesMerge.merge(
            [PythonBridge.PieceNoteResult(title: "Bolero", composer: "Ravel",
                                          notes: "Written in 1928.")],
            into: &pieces)

        XCTAssertFalse(changed)
        XCTAssertEqual(pieces.first?.notes, "")
    }

    func testAnEmptyNoteIsNotAnAnswer() {
        // The model returning nothing for a work is not a note saying nothing.
        var pieces = [Piece(composer: "Beethoven", title: "Symphony No. 5")]
        XCTAssertFalse(ProgramNotesMerge.merge([Self.result(nil)], into: &pieces))
        XCTAssertFalse(ProgramNotesMerge.merge([Self.result("   ")], into: &pieces))
    }

    // MARK: - Wired into the screen

    func testTheReviewScreenReadsTheRunFromTheManager() throws {
        // All of the above can be right while the screen still keeps its own
        // copy of the run, which is the defect: what Dan sees would go on being
        // destroyed by the collapse (L3).
        let code = try Self.reviewSource()

        XCTAssertTrue(code.contains("notesManager.isRunning(event.id)"),
                      "the screen does not ask the manager whether a search is "
                      + "running, so its indicator is not the run's")
        XCTAssertTrue(code.contains("notesManager.failure(for: event.id)"),
                      "the failure shown is not the one the manager kept, so a "
                      + "search that failed while the section was closed still "
                      + "says nothing when it reopens")
        XCTAssertFalse(code.contains("@State private var isFetchingNotes"),
                       "the editor still holds the run's state itself, and it is "
                       + "destroyed every time another section is opened")
    }

    func testTheDraftIsNotWrittenBackOverNotesThatJustLanded() throws {
        // The notes are written to the stored event while the screen holds an
        // older draft. Without this the next keystroke persists that draft back
        // over them, which is how #518's rescan lost the pages it had just read.
        let code = try Self.reviewSource()
        XCTAssertTrue(code.contains("guard !notesManager.isRunning(event.id) else { return }"),
                      "nothing stops the on screen draft being saved over a "
                      + "notes search that is still writing: \(code.count) chars read")
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

    /// Counts calls from whichever thread makes them.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
