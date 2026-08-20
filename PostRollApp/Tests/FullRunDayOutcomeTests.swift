import XCTest

/// #740: a day that failed inside the whole week rebuild recorded nothing.
///
/// `PreviewGraphicsManager.startFullRun` wrote `result.paths` back onto the
/// event and never looked at `result.errors`, so a day that died during a full
/// run left no failure on the manager, no `mediaErrors` entry from that path,
/// and nothing on screen saying why. The single-day path records all of it,
/// through `applyRegenResult`.
///
/// It matters twice. The reason is lost, which is the shape #721 was filed
/// about, one entry point further out. And Friday's "< 3 usable clips" escape
/// hatch, restored in #730, is reached FROM the recorded failure, so a shortfall
/// that happened during a full run left Dan with no way out of a state that
/// fails identically on every retry.
///
/// These drive the write-back directly rather than `startFullRun`, which goes
/// to PythonBridge and a real subprocess. What is under test is what a finished
/// run's result means, which is the half that was missing.
@MainActor
final class FullRunDayOutcomeTests: XCTestCase {

    private var root: URL!

    // async throws, not setUpWithError: on a @MainActor test class the
    // non-isolated variant cannot touch a main-actor property.
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-run-outcome-\(UUID().uuidString)")
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

    private func result(paths: [String: [String: String]] = [:],
                        errors: [String: String] = [:],
                        warnings: [String: String] = [:])
    -> PythonBridge.PreviewGenerationResult {
        PythonBridge.PreviewGenerationResult(paths: paths, errors: errors, warnings: warnings)
    }

    private let shortfall = "insufficient_clips: only 1 of 1 clips usable, need at least 3"

    // MARK: - The defect

    func testAFailedDayIsRecordedOnTheManager() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])

        manager.applyFullRunResult(
            result(paths: ["tuesday": ["story": "/tmp/story.png"]],
                   errors: ["friday": "clip reel skipped: ffmpeg crashed"]),
            for: event.id, appState: appState)

        XCTAssertEqual(manager.dayFailure(.friday, for: event.id)?.reason,
                       "Friday regeneration failed: clip reel skipped: ffmpeg crashed",
                       "a day that failed inside the full run said nothing at all")
    }

    func testTheMarkerSurvivesSoFridaysEscapeHatchIsReachable() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])

        manager.applyFullRunResult(result(errors: ["friday": shortfall]),
                                   for: event.id, appState: appState)

        // The whole point of recording it through failDayRegen(_:for:pipelineError:)
        // rather than a second implementation beside it: the prefix the card
        // matches on has to reach the card (#730).
        XCTAssertTrue(FridayReviewDisplay.offersInsufficientClipsEscape(
            manager.dayFailure(.friday, for: event.id)))
    }

    func testARunThatProducedNothingAtAllStillRecordsWhy() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])

        // The early `guard !result.paths.isEmpty else { return }`: the run where
        // every day failed is the one that returned before recording anything,
        // which is the worst case reading as the quietest (L98).
        manager.applyFullRunResult(
            result(errors: ["tuesday": "missing photo", "friday": shortfall]),
            for: event.id, appState: appState)

        XCTAssertEqual(manager.dayFailures(for: event.id).map(\.day), [.tuesday, .friday])
    }

    func testTheAssetScreenGetsTheFailureToo() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])

        manager.applyFullRunResult(result(errors: ["friday": "missing photo"]),
                                   for: event.id, appState: appState)

        XCTAssertEqual(appState.events.first?.mediaErrors["friday"], "missing photo",
                       "the asset screen's failure list never heard about it")
    }

    func testAWarningIsNotRecordedAsAFailure() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])

        manager.applyFullRunResult(
            result(paths: ["wednesday": ["collage": "/tmp/collage.png"]],
                   warnings: ["wednesday": "an optional photo had moved"]),
            for: event.id, appState: appState)

        // A day that rendered without an optional input is not a day with no
        // graphics, and folding the two together is #265.
        XCTAssertEqual(appState.events.first?.mediaWarnings["wednesday"],
                       "an optional photo had moved")
        XCTAssertNil(manager.dayFailure(.wednesday, for: event.id))
        XCTAssertNil(appState.events.first?.mediaErrors["wednesday"])
    }

    // MARK: - What the run already did, still done

    func testTheDaysThatRenderedStillLand() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])

        manager.applyFullRunResult(
            result(paths: ["tuesday": ["story": "/tmp/story.png"]],
                   errors: ["friday": shortfall]),
            for: event.id, appState: appState)

        XCTAssertEqual(appState.events.first?.previewMediaPaths["tuesday"]?["story"],
                       "/tmp/story.png",
                       "recording the failures cost the run the days that worked")
    }

    func testADayThatRenderedClearsTheFailureAnEarlierRunLeft() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])
        manager.failDayRegen(.friday, for: event.id, pipelineError: shortfall)

        manager.applyFullRunResult(
            result(paths: ["friday": ["reel": "/tmp/reel.mp4"]]),
            for: event.id, appState: appState)

        // A reason that outlives the run it was about reads as a failure
        // happening now, on a day the rebuild has just fixed (L14).
        XCTAssertNil(manager.dayFailure(.friday, for: event.id))
    }

    func testADayTheRunNeverProducedKeepsItsEarlierFailure() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])
        manager.failDayRegen(.thursday, for: event.id, reason: "Thursday audio swap failed.")

        manager.applyFullRunResult(
            result(paths: ["tuesday": ["story": "/tmp/story.png"]]),
            for: event.id, appState: appState)

        // Nothing here re-attempted Thursday, so nothing here may say its
        // failure is over (L5).
        XCTAssertEqual(manager.dayFailure(.thursday, for: event.id)?.reason,
                       "Thursday audio swap failed.")
    }

    // MARK: - A day rebuilding on its own

    func testADayRebuildingOnItsOwnKeepsItsRun() {
        let manager = PreviewGraphicsManager()
        let event = makeEvent()
        let appState = state([event])
        XCTAssertTrue(manager.beginDayRegen(.friday, for: event.id))

        // Tuesday is the positive control, in the SAME result: a negative
        // assertion is satisfied by a fixture where the recording could not
        // have happened at all, so this proves the path is live here before
        // reading anything into Friday's silence (L159).
        manager.applyFullRunResult(
            result(errors: ["friday": shortfall, "tuesday": "missing photo"]),
            for: event.id, appState: appState)

        XCTAssertEqual(manager.dayFailure(.tuesday, for: event.id)?.reason,
                       "Tuesday regeneration failed: missing photo")
        // `failDayRegen` records AND releases the slot, so landing a full run's
        // answer for a day somebody else is rebuilding would take down that
        // rebuild's in-flight marker while its subprocess ran on, leaving the
        // day free to be started a third time: two writers on one MP4 (#75).
        XCTAssertTrue(manager.regeneratingDays(event.id).contains(.friday))
        XCTAssertNil(manager.dayFailure(.friday, for: event.id),
                     "this run's answer for Friday predates the rebuild now running")
    }
}
