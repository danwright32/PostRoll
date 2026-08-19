import XCTest

/// The "describe the correction" reflow outlives the row that started it
/// (#718, the third of the three #707 listed).
///
/// It kept its in flight flag, its error and Claude's reply in `FlagRow`'s own
/// `@State`, and wrote the corrected result back through a closure into
/// `OCRReviewView`'s draft. Both die with the screen, and this screen is
/// `.id(event.id)` tagged, so switching events remounts the lot. A paid model
/// call then finished into nothing: the correction was lost rather than merely
/// unreported, and the row came back looking idle so a second could be stacked
/// on the first.
///
/// The result now goes to the STORED event, the same way the rescan (#518) and
/// the notes search (#693) write, and the screen takes it up from there.
///
/// Almost everything here is a failure or an interruption. A happy path test
/// cannot tell any of it apart: the reflow always worked when nobody moved.
@MainActor
final class OCRReflowManagerTests: XCTestCase {

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("OCRReflow-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let flagID = "flag-1"
    /// A SECOND concern that really is on the event.
    ///
    /// The refusal test below used an id that was not on the fixture at all,
    /// so the second run was stopped by the flag lookup rather than by the
    /// refusal, and the test passed with the refusal deleted. Caught by the
    /// mutation registry, which is the whole reason it exists (L1).
    private static let otherFlagID = "flag-2"

    private func flag(_ id: String = flagID) -> OCRFlag {
        OCRFlag(id: id, fieldPath: [.key("performers")],
                currentValue: "Ordway", suggestedValue: "Traditional Chinese",
                concern: "the composer may be the arranger",
                programContext: "page 3")
    }

    private func event(pieceTitle: String = "Symphony No. 5") -> Event {
        var event = Event(name: "Spring Gala", org: "Decoda", venue: "Merkin Hall",
                          date: Date(), shootType: .fullShow)
        event.stage = .ocrDone
        event.programImagePaths = [URL(fileURLWithPath: "/tmp/page1.png")]
        event.ocrResult = OCRResult(pieces: [
            Piece(composer: "Beethoven", title: pieceTitle),
        ])
        event.pendingFlags = [flag(), flag(Self.otherFlagID)]
        return event
    }

    private func state(_ events: [Event]) -> AppState {
        AppState(events: events,
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    nonisolated private static func corrected(_ title: String) -> OCRResult {
        OCRResult(pieces: [Piece(composer: "Traditional Chinese", title: title)])
    }

    nonisolated private static func reply(_ text: String, resolved: Bool = true)
        -> PythonBridge.FlagReviewResponse {
        PythonBridge.FlagReviewResponse(assistantReply: text, patch: nil,
                                        resolved: resolved)
    }

    /// A manager whose model call is this test rather than a paid one (L2).
    private func manager(
        reply: @escaping @Sendable (OCRFlag, OCRResult, [URL], String) async throws
            -> PythonBridge.FlagReviewResponse,
        corrected: OCRResult? = nil
    ) -> OCRReflowManager {
        let manager = OCRReflowManager()
        manager.review = reply
        if let corrected {
            manager.applyPatch = { _, _, _, _ in corrected }
        }
        return manager
    }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - It lands wherever Dan happens to be

    func testACorrectionLandsOnTheStoredEventWithNoScreenWatching() async throws {
        // Nothing here renders anything, which is the state the app is in the
        // moment Dan selects another event while the reflow is running.
        let event = event()
        let state = state([event])
        let manager = manager(
            reply: { _, _, _, _ in
                Self.reply("Composer corrected.", resolved: false)
            },
            corrected: Self.corrected("Butterfly Lovers"))
        // A patch has to come back for the correction to be applied at all.
        manager.review = { _, _, _, _ in
            PythonBridge.FlagReviewResponse(
                assistantReply: "Composer corrected.",
                patch: try Self.onePatchOp(), resolved: false)
        }

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "the composer is the arranger",
                      appState: state)
        await settle()

        XCTAssertEqual(state.events.first?.ocrResult?.pieces.first?.composer,
                       "Traditional Chinese",
                       "the reflow finished into nothing, so a paid model call "
                       + "and Dan's correction were both thrown away")
    }

    func testACorrectionLandsOnTheEventItWasStartedFor() async throws {
        let first = event()
        var second = Event(name: "Other", org: "Other", venue: "Hall",
                           date: Date(), shootType: .fullShow)
        second.stage = .ocrDone
        second.ocrResult = OCRResult(pieces: [Piece(composer: "Ravel", title: "Bolero")])
        let state = state([first, second])
        let manager = manager(reply: { _, _, _, _ in Self.reply("done") },
                              corrected: Self.corrected("Butterfly Lovers"))
        manager.review = { _, _, _, _ in
            PythonBridge.FlagReviewResponse(assistantReply: "done",
                                            patch: try Self.onePatchOp(),
                                            resolved: true)
        }

        manager.start(eventID: first.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        state.selectedEventID = second.id       // Dan moves on while it runs
        await settle()

        XCTAssertEqual(state.events.first(where: { $0.id == first.id })?
            .ocrResult?.pieces.first?.composer, "Traditional Chinese")
        XCTAssertEqual(state.events.first(where: { $0.id == second.id })?
            .ocrResult?.pieces.first?.composer, "Ravel",
                       "the correction landed on the event that happened to be "
                       + "open rather than the one it was about")
    }

    func testAResolvedFlagIsMarkedOnTheStoredEvent() async throws {
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in Self.reply("that is fixed") })

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        await settle()

        XCTAssertEqual(state.events.first?.pendingFlags.first?.resolved, true,
                       "Claude said the concern was resolved and the flag is "
                       + "still outstanding on the stored event, so it comes "
                       + "back the next time the screen is opened")
    }

    func testAnUnresolvedFlagIsLeftAloneRatherThanQuietlyCleared() async throws {
        // The other half of the same decision. A reflow that only ANSWERED a
        // question must not tidy the concern away.
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in
            Self.reply("I am not sure, check page 4", resolved: false)
        })

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "who is the composer", appState: state)
        await settle()

        XCTAssertEqual(state.events.first?.pendingFlags.first?.resolved, false)
    }

    // MARK: - Three states that must not look alike

    func testTheReplySurvivesTheRowThatAskedForIt() async throws {
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in Self.reply("Composer corrected.") })

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        await settle()

        XCTAssertEqual(manager.reply(for: event.id, flag: Self.flagID),
                       "Composer corrected.",
                       "Claude's answer died with the row, so a paid call Dan "
                       + "was waiting on left nothing behind")
    }

    func testTheReplyBelongsToTheFlagItWasAbout() async throws {
        // Several flags are on screen at once. An answer shown against the
        // wrong concern is worse than no answer.
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in Self.reply("Composer corrected.") })

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        await settle()

        XCTAssertNil(manager.reply(for: event.id, flag: "some-other-flag"))
    }

    func testAFailedReflowKeepsItsReasonAfterTheRowIsGone() async throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "no program images available" }
        }
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in throw Refused() })

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        await settle()

        XCTAssertFalse(manager.isRunning(event.id))
        XCTAssertEqual(manager.failure(for: event.id, flag: Self.flagID),
                       "no program images available",
                       "the reason died with the row, so Dan is left pressing "
                       + "the same button with nothing to read (L148)")
    }

    func testAFailedReflowChangesNothing() async throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "no program images available" }
        }
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in throw Refused() })

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        await settle()

        XCTAssertEqual(state.events.first?.ocrResult?.pieces.first?.composer,
                       "Beethoven", "a failed reflow wrote something anyway")
        XCTAssertEqual(state.events.first?.pendingFlags.first?.resolved, false)
    }

    func testAStalledReflowBecomesAnErrorRatherThanAnIndicatorForever() async throws {
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.reply("never")
        })
        manager.deadlineForTesting = 0.05

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        await settle()

        XCTAssertFalse(manager.isRunning(event.id))
        let failure = try XCTUnwrap(manager.failure(for: event.id, flag: Self.flagID))
        XCTAssertTrue(failure.lowercased().contains("come back"),
                      "a run that never returned was reported as some other "
                      + "kind of failure: \(failure)")
    }

    func testWhichFlagIsRunningIsVisible() async throws {
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return Self.reply("done")
        })

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)

        XCTAssertTrue(manager.isRunning(event.id, flag: Self.flagID))
        XCTAssertFalse(manager.isRunning(event.id, flag: "some-other-flag"),
                       "every other row on the screen showed a spinner for a "
                       + "correction that is not theirs")
        XCTAssertNotNil(manager.startedAt(event.id))
        await settle()
    }

    // MARK: - It refuses to run twice

    func testASecondReflowOnTheSameEventIsRefusedWhileOneIsGoing() async throws {
        // Not merely tidiness. Each reflow returns a WHOLE replacement result
        // computed from the state it started with, so two running at once means
        // the second silently discards the first's correction, and the paid call
        // that produced it (L5).
        let event = event()
        let state = state([event])
        let calls = Counter()
        let manager = manager(reply: { _, _, _, _ in
            await calls.bump()
            try await Task.sleep(for: .milliseconds(200))
            return Self.reply("done")
        })

        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        manager.start(eventID: event.id, flag: Self.otherFlagID,
                      userMessage: "and this", appState: state)
        await settle()

        let count = await calls.value
        XCTAssertEqual(count, 1, "a second correction ran over the first, and "
                       + "whichever landed last silently discarded the other")
    }

    func testTwoEventsReflowIndependently() async throws {
        // A refusal scoped to the event, not to the app: two events are two
        // different results and cannot overwrite each other.
        let first = event()
        var second = event()
        second.id = UUID()
        let state = state([first, second])
        let calls = Counter()
        let manager = manager(reply: { _, _, _, _ in
            await calls.bump()
            try await Task.sleep(for: .milliseconds(150))
            return Self.reply("done")
        })

        manager.start(eventID: first.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        manager.start(eventID: second.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        await settle()

        let count = await calls.value
        XCTAssertEqual(count, 2)
    }

    func testTheButtonIsUnavailableWhileAnotherCorrectionIsGoing() async throws {
        // What the row asks, so the control can be disabled with a reason
        // instead of swallowing the press (L109).
        let event = event()
        let state = state([event])
        let manager = manager(reply: { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return Self.reply("done")
        })

        XCTAssertTrue(manager.canStart(event.id))
        manager.start(eventID: event.id, flag: Self.flagID,
                      userMessage: "fix it", appState: state)
        XCTAssertFalse(manager.canStart(event.id))
        await settle()
        XCTAssertTrue(manager.canStart(event.id),
                      "the button stayed dead after the correction finished")
    }

    func testTheReasonTheButtonIsDeadSaysWhatToDoNext() {
        // A message naming no next step leaves Dan guessing, and this one is
        // the only thing the row can say about a control it has disabled.
        XCTAssertTrue(OCRReflowText.busyElsewhere.contains("as soon as that finishes"),
                      "the notice does not say when this will be possible: "
                      + OCRReflowText.busyElsewhere)
    }

    /// One real patch operation, decoded the way the bridge decodes them, so
    /// the fixture is the shape Python actually returns rather than one shaped
    /// to make the code under test happy (L48).
    nonisolated private static func onePatchOp() throws -> [PythonBridge.PatchOp] {
        let json = Data("""
        [{"op": "replace", "path": ["pieces", "0", "composer"], "value": "Traditional Chinese"}]
        """.utf8)
        return try JSONDecoder().decode([PythonBridge.PatchOp].self, from: json)
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}
