import XCTest

/// #750: a day that died during a WHOLE WEEK generation recorded nothing where
/// the caption review screen reads it.
///
/// `GenerationManager` runs its own full preview pass alongside the captions
/// and folds that run's per-day errors into the event's `mediaErrors`, which
/// the asset screen reads. It never told `PreviewGraphicsManager`, so the
/// caption review screen showed no day failure row, and Friday's "< 3 usable
/// clips" escape hatch, which is reached FROM the recorded failure, was
/// unreachable for every day that failed this way.
///
/// This is #740 one entry point over. That fixed the full run started from the
/// caption screen itself, through `applyFullRunResult`. The recording lives in
/// `PreviewGraphicsManager.recordDayOutcomes` so both paths land through one
/// implementation rather than two that can disagree.
///
/// These drive the completion directly rather than `start`, which goes to
/// PythonBridge and a real subprocess. What is under test is what a finished
/// run's graphics outcome MEANS, which is the half that was missing.
@MainActor
final class GenerationRunDayOutcomeTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("generation-run-outcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A state object pointed at this suite's own tree (#684), never the live
    /// events.json or media root.
    private func state(_ events: [Event]) -> AppState {
        AppState(events: events,
                 storeURL: root.appendingPathComponent("events.json"),
                 dataRoot: root)
    }

    private func makeEvent() -> Event {
        Event(name: "Music From Inside", org: "Decoda", venue: "Hall",
              date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
    }

    /// Its own manager, never `.shared`: a suite that writes into the app-scoped
    /// one is writing into whatever else the run touches (L205).
    private func managers() -> (GenerationManager, PreviewGraphicsManager) {
        let graphics = PreviewGraphicsManager()
        return (GenerationManager(graphics: graphics), graphics)
    }

    private let shortfall = "insufficient_clips: only 1 of 1 clips usable, need at least 3"

    // MARK: - The defect

    func testADayThatFailedDuringAWholeWeekGenerationIsRecorded() {
        let (generation, graphics) = managers()
        let event = makeEvent()
        let appState = state([event])

        generation.finishSuccess(
            eventID: event.id, snapshot: event, onlyDays: nil,
            result: WeekGenerationResult(),
            mediaPaths: ["tuesday": ["story": "/tmp/story.png"]],
            mediaErrors: ["friday": "clip reel skipped: ffmpeg crashed"],
            renderedDays: nil, appState: appState)

        XCTAssertEqual(graphics.dayFailure(.friday, for: event.id)?.reason,
                       "Friday regeneration failed: clip reel skipped: ffmpeg crashed",
                       "a day that died during the whole week generation left no "
                       + "failure row on the caption review screen")
    }

    func testFridaysEscapeHatchIsReachableFromAWholeWeekGeneration() {
        let (generation, graphics) = managers()
        let event = makeEvent()
        let appState = state([event])

        generation.finishSuccess(
            eventID: event.id, snapshot: event, onlyDays: nil,
            result: WeekGenerationResult(), mediaPaths: nil,
            mediaErrors: ["friday": shortfall],
            renderedDays: nil, appState: appState)

        // Recorded through `failDayRegen(_:for:pipelineError:)` rather than a
        // second implementation beside it, so the pipeline's marker survives to
        // the card that offers the remedy (#730).
        XCTAssertTrue(FridayReviewDisplay.offersInsufficientClipsEscape(
            graphics.dayFailure(.friday, for: event.id)),
            "the shortfall reached the event but not the card that offers the way out")
    }

    func testASalvagedRunRecordsTheDaysThatDied() {
        // The watchdog killed the run with days already generated. The graphics
        // ran in their own process and their per-day answers are just as real
        // as a finished run's, so they are recorded the same way (#262).
        let (generation, graphics) = managers()
        let event = makeEvent()
        let appState = state([event])

        generation.saveSalvagedDays(
            eventID: event.id, snapshot: event, week: WeekGenerationResult(),
            mediaPaths: nil, mediaErrors: ["friday": shortfall],
            mediaWarnings: [:], renderedDays: nil, appState: appState)

        XCTAssertNotNil(graphics.dayFailure(.friday, for: event.id),
                        "a day that died inside a run the watchdog killed said nothing")
    }

    // MARK: - What it may not take away

    func testACaptionOnlyRetryTakesNothingAway() {
        // Graphics did not run at all, so this run knows nothing about any day
        // and may not clear a reason it never re-attempted (L5).
        let (generation, graphics) = managers()
        let event = makeEvent()
        let appState = state([event])
        graphics.failDayRegen(.friday, for: event.id, pipelineError: shortfall)

        generation.finishSuccess(
            eventID: event.id, snapshot: event, onlyDays: ["tuesday"],
            result: WeekGenerationResult(),
            mediaPaths: nil, mediaErrors: [:],
            renderedDays: [], appState: appState)

        XCTAssertNotNil(graphics.dayFailure(.friday, for: event.id),
                        "a caption-only retry erased a failure it never re-attempted")
    }

    func testADayThisRunRebuiltClearsTheReasonTheRunBeforeLeft() {
        let (generation, graphics) = managers()
        let event = makeEvent()
        let appState = state([event])
        graphics.failDayRegen(.friday, for: event.id, pipelineError: shortfall)

        generation.finishSuccess(
            eventID: event.id, snapshot: event, onlyDays: nil,
            result: WeekGenerationResult(),
            mediaPaths: ["friday": ["reel": "/tmp/reel.mp4"]],
            mediaErrors: [:], renderedDays: nil, appState: appState)

        // A reason that outlives the run it was about reads as a failure
        // happening now, on a day this run has just fixed (L14).
        XCTAssertNil(graphics.dayFailure(.friday, for: event.id))
    }

    func testADayRebuildingOnItsOwnKeepsItsRun() {
        let (generation, graphics) = managers()
        let event = makeEvent()
        let appState = state([event])
        XCTAssertTrue(graphics.beginDayRegen(.friday, for: event.id))

        // Tuesday is the positive control, in the SAME result: a negative
        // assertion is satisfied by a fixture where the recording could not
        // have happened at all, so this proves the path is live here before
        // reading anything into Friday's silence (L159).
        generation.finishSuccess(
            eventID: event.id, snapshot: event, onlyDays: nil,
            result: WeekGenerationResult(), mediaPaths: nil,
            mediaErrors: ["friday": shortfall, "tuesday": "missing photo"],
            renderedDays: nil, appState: appState)

        XCTAssertEqual(graphics.dayFailure(.tuesday, for: event.id)?.reason,
                       "Tuesday regeneration failed: missing photo")
        // `failDayRegen` records AND releases the slot, so landing this run's
        // answer for a day somebody else is rebuilding would take down that
        // rebuild's in-flight marker while its subprocess ran on: two writers
        // on one MP4, which is the hazard #75 exists for.
        XCTAssertTrue(graphics.regeneratingDays(event.id).contains(.friday))
        XCTAssertNil(graphics.dayFailure(.friday, for: event.id),
                     "this run's answer for Friday predates the rebuild now running")
    }

    func testTheRunLevelGraphicsCrashIsNotFiledAgainstADay() {
        // A graphics pass that died outright reports under a key naming no day
        // (`PreviewMergePolicy.graphicsRunKey`). Filing that against a day would
        // put a run-level crash on one card and leave the other five looking
        // fine.
        let (generation, graphics) = managers()
        let event = makeEvent()
        let appState = state([event])

        generation.finishSuccess(
            eventID: event.id, snapshot: event, onlyDays: nil,
            result: WeekGenerationResult(), mediaPaths: nil,
            mediaErrors: [PreviewMergePolicy.graphicsRunKey: "ffmpeg is not installed."],
            renderedDays: nil, appState: appState)

        XCTAssertTrue(graphics.dayFailures(for: event.id).isEmpty)
        XCTAssertEqual(appState.events.first?.mediaErrors[PreviewMergePolicy.graphicsRunKey],
                       "ffmpeg is not installed.",
                       "the run-level crash has to reach the asset screen even so")
    }

    // MARK: - What the completion already did, still done

    func testTheDaysThatRenderedStillLand() {
        let (generation, _) = managers()
        let event = makeEvent()
        let appState = state([event])

        generation.finishSuccess(
            eventID: event.id, snapshot: event, onlyDays: nil,
            result: WeekGenerationResult(),
            mediaPaths: ["tuesday": ["story": "/tmp/story.png"]],
            mediaErrors: ["friday": shortfall],
            renderedDays: nil, appState: appState)

        XCTAssertEqual(appState.events.first?.previewMediaPaths["tuesday"]?["story"],
                       "/tmp/story.png",
                       "recording the failures cost the run the days that worked")
        XCTAssertEqual(appState.events.first?.mediaErrors["friday"], shortfall)
    }
}
