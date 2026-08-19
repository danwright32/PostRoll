import XCTest

/// The runs started from the caption review screen outlive it (#718).
///
/// Every one of them kept its in flight flag, its start time and its error in
/// the view's own `@State`. `EventDetailView` is `.id(event.id)` tagged, so an
/// event switch remounts the whole screen and destroys all three.
///
/// The whole-week regeneration is the worst of them. It is three to six minutes
/// of paid Claude output, and the two ways it can end EARLY, a usage cap and a
/// mid-run failure, both keep the days they finished and hand back a banner
/// saying which survived and what to do next (#262). That banner lived in the
/// view. Losing it does not merely leave Dan uninformed: he re-runs, and pays
/// again, for work he already has.
///
/// Almost everything here is a failure or an interruption, because those are
/// the states that used to leave nothing on the screen.
@MainActor
final class CaptionWorkManagerTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaptionWork-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func event() -> Event {
        var event = Event(name: "Spring Gala", org: "Decoda", venue: "Merkin Hall",
                          date: Date(), shootType: .fullShow)
        event.stage = .assetsGenerated
        event.weekResult = Self.week([.sunday: "old sun", .monday: "old mon"])
        return event
    }

    private func state(_ events: [Event]) -> AppState {
        AppState(events: events,
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    nonisolated private static func week(_ days: [DayName: String],
                                         stoppedReason: String? = nil,
                                         complete: Bool = true) -> WeekGenerationResult {
        var w = WeekGenerationResult()
        for (day, caption) in days { w[day] = DayCaption(caption: caption) }
        w.stoppedReason = stoppedReason
        w.complete = complete
        return w
    }

    private func manager(
        _ generate: @escaping @Sendable (Event) async throws -> WeekGenerationResult
    ) -> CaptionWorkManager {
        let manager = CaptionWorkManager()
        manager.generateWeek = generate
        return manager
    }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - It finishes whether or not anyone is looking

    func testARegeneratedWeekLandsOnTheStoredEventWithNoScreenWatching() async throws {
        let event = event()
        let state = state([event])
        let manager = manager { _ in Self.week([.sunday: "new sun"]) }

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])
        await settle()

        XCTAssertEqual(state.events.first?.weekResult?.sunday?.caption, "new sun",
                       "three to six minutes of paid Claude output completed "
                       + "into nothing")
    }

    func testARegeneratedWeekLandsOnTheEventItWasStartedFor() async throws {
        let first = event()
        var second = event()
        second.id = UUID()
        second.weekResult = Self.week([.sunday: "other sun"])
        let state = state([first, second])
        let manager = manager { _ in Self.week([.sunday: "new sun"]) }

        manager.startRegeneratingWeek(eventID: first.id, appState: state,
                                      globalHashtags: [])
        state.selectedEventID = second.id       // Dan moves on while it runs
        await settle()

        XCTAssertEqual(state.events.first(where: { $0.id == first.id })?
            .weekResult?.sunday?.caption, "new sun")
        XCTAssertEqual(state.events.first(where: { $0.id == second.id })?
            .weekResult?.sunday?.caption, "other sun",
                       "the week landed on whichever event happened to be open")
    }

    func testGlobalHashtagsAreMergedIntoWhatCameBack() async throws {
        let event = event()
        let state = state([event])
        let manager = manager { _ in Self.week([.sunday: "new sun"]) }

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: ["#nyc"])
        await settle()

        XCTAssertEqual(state.events.first?.weekResult?.sunday?.hashtags, ["#nyc"],
                       "the global tags were merged into the view's copy only, "
                       + "so they were lost with it")
    }

    // MARK: - The two ways a run ends early (#262)

    func testAHaltKeepsTheDaysItFinishedAndSaysWhichSurvived() async throws {
        let event = event()
        let state = state([event])
        let manager = manager { _ in
            throw WeekGenerationHalted(
                week: Self.week([.sunday: "new sun"], stoppedReason: "usage cap reached",
                                complete: false))
        }

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])
        await settle()

        let stored = try XCTUnwrap(state.events.first?.weekResult)
        XCTAssertEqual(stored.sunday?.caption, "new sun",
                       "the day the run did finish, and was paid for, was thrown "
                       + "away with the error")
        XCTAssertEqual(stored.monday?.caption, "old mon",
                       "a day the run never reached was overwritten with nothing")

        let banner = try XCTUnwrap(manager.outcome(for: event.id, .regenerateWeek)?.failure)
        XCTAssertFalse(banner.isEmpty)
        XCTAssertFalse(manager.isRunning(event.id, .regenerateWeek))
    }

    func testAMidRunFailureKeepsWhatItProducedAndItsReason() async throws {
        struct Died: LocalizedError {
            var errorDescription: String? { "the run died after Sunday" }
        }
        let event = event()
        let state = state([event])
        let manager = manager { _ in
            throw WeekGenerationFailedWithPartial(
                underlying: Died(),
                week: Self.week([.sunday: "new sun"], complete: false))
        }

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])
        await settle()

        XCTAssertEqual(state.events.first?.weekResult?.sunday?.caption, "new sun")
        XCTAssertEqual(manager.outcome(for: event.id, .regenerateWeek)?.failure,
                       "the run died after Sunday")
    }

    func testTheBannerIsStillThereAfterTheScreenIsGone() async throws {
        // The point of the whole change. Nothing here renders anything, which
        // is the state the app is in the moment Dan clicks another event, and
        // a banner he never reads is a re-run he pays for twice.
        let event = event()
        let state = state([event])
        let manager = manager { _ in
            throw WeekGenerationHalted(
                week: Self.week([.sunday: "new sun"], stoppedReason: "usage cap reached",
                                complete: false))
        }

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])
        await settle()
        state.selectedEventID = UUID()          // the screen goes away

        XCTAssertNotNil(manager.outcome(for: event.id, .regenerateWeek)?.failure)
    }

    func testAPlainFailureChangesNothingAndKeepsItsReason() async throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "the model refused the request" }
        }
        let event = event()
        let state = state([event])
        let manager = manager { _ in throw Refused() }

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])
        await settle()

        XCTAssertEqual(state.events.first?.weekResult?.sunday?.caption, "old sun",
                       "a run that produced nothing wrote over the existing week")
        XCTAssertEqual(manager.outcome(for: event.id, .regenerateWeek)?.failure,
                       "the model refused the request")
    }

    func testAStalledRegenerationBecomesAnErrorRatherThanAnIndicatorForever() async throws {
        let event = event()
        let state = state([event])
        let manager = manager { _ in
            try await Task.sleep(for: .seconds(30))
            return Self.week([.sunday: "never"])
        }
        manager.deadlineForTesting = 0.05

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])
        await settle()

        XCTAssertFalse(manager.isRunning(event.id, .regenerateWeek))
        let failure = try XCTUnwrap(manager.outcome(for: event.id, .regenerateWeek)?.failure)
        XCTAssertTrue(failure.lowercased().contains("come back"),
                      "a run that never returned was reported as some other kind "
                      + "of failure: \(failure)")
    }

    // MARK: - It refuses to run twice

    func testASecondRegenerationIsRefusedWhileOneIsGoing() async throws {
        // Coming back to the screen showed the idle button, so stacking two
        // whole-week runs, each three to six paid minutes, on one event was one
        // click away, and both write the same week.
        let event = event()
        let state = state([event])
        let calls = Counter()
        let manager = manager { _ in
            await calls.bump()
            try await Task.sleep(for: .milliseconds(200))
            return Self.week([.sunday: "new sun"])
        }

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])
        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])
        await settle()

        let count = await calls.value
        XCTAssertEqual(count, 1, "a second whole-week run started over the first")
    }

    func testTwoEventsRegenerateIndependently() async throws {
        let first = event()
        var second = event()
        second.id = UUID()
        let state = state([first, second])
        let calls = Counter()
        let manager = manager { _ in
            await calls.bump()
            try await Task.sleep(for: .milliseconds(150))
            return Self.week([.sunday: "new sun"])
        }

        manager.startRegeneratingWeek(eventID: first.id, appState: state,
                                      globalHashtags: [])
        manager.startRegeneratingWeek(eventID: second.id, appState: state,
                                      globalHashtags: [])
        await settle()

        let count = await calls.value
        XCTAssertEqual(count, 2)
    }

    func testARunningRegenerationIsVisibleToTheUpdater() async throws {
        // Updating quits the app to install (#686). Three to six paid minutes
        // half way through is exactly what must not be thrown away silently.
        let event = event()
        let state = state([event])
        let manager = manager { _ in
            try await Task.sleep(for: .milliseconds(200))
            return Self.week([.sunday: "new sun"])
        }
        XCTAssertFalse(manager.hasWorkInFlight)

        manager.startRegeneratingWeek(eventID: event.id, appState: state,
                                      globalHashtags: [])

        XCTAssertTrue(manager.hasWorkInFlight)
        XCTAssertNotNil(manager.startedAt(event.id, .regenerateWeek))
        await settle()
        XCTAssertFalse(manager.hasWorkInFlight)
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: - The screen's draft, which is the other half of this

    /// Built is not wired (L3). The manager writing the regenerated week to the
    /// store is only half the change: the review screen holds a DRAFT of that
    /// week and persists it on every edit, so without taking up what landed
    /// underneath it, the next keystroke writes the pre-regeneration week back
    /// over three to six paid minutes of output. That is #518, on the other
    /// screen, and it did not merely read as a failed save there, it became one.
    ///
    /// Checked as source rather than by rendering, the same way the programme
    /// review screen's half is checked, with comments stripped so prose about
    /// the rule cannot answer for the rule (L103).
    func testTheCaptionScreenAdoptsAndStopsPersistingDuringARegeneration() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/CaptionReviewView.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("DraftRefresh.shouldAdopt"),
                      "the screen never takes up the regenerated week, so it "
                      + "will write its older draft back over it")
        XCTAssertTrue(
            code.contains("guard !captionWork.isRunning(event.id, .regenerateWeek) else { return }"),
            "the draft is still persisted while a regeneration is in flight, so "
            + "an edit mid-run overwrites the week that is landing")
    }
}
