import XCTest

/// Preview-graphics runs used to live in CaptionReviewView's @State, which the
/// `.id(event.id)` remount on every event switch throws away while the
/// unstructured Task keeps going. Coming back auto-started a second run against
/// the same output files, and the first one became invisible (#75).
///
/// Ownership moved to an app-scoped manager over this state, so the rule that
/// makes that safe is pinned here: a second start for an event already running
/// is refused, and what's in flight outlives any view.
final class PreviewRunStateTests: XCTestCase {

    private let eventA = UUID()
    private let eventB = UUID()

    // MARK: - A full run and a day run are the same writer (#1009)

    /// The two claims never consulted each other, so both said yes for one
    /// event and two `generate_media` subprocesses ran against the same files.
    ///
    /// They also collide on one file: `PythonBridge.runPreviewGeneration`
    /// deletes `AppPaths.mediaProgressFile(forEventID:)`, which is per EVENT,
    /// and `AppPaths` carries a comment recording why sharing that file is
    /// wrong (one overwrites the other's label, so the screen flips and neither
    /// surface can trust what it reads). Making the claims exclusive is what
    /// removes the collision, rather than a second fix on the file.
    func testADayRegenIsRefusedWhileAFullRunIsInFlight() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginFullRun(eventA))

        XCTAssertFalse(state.beginDay(.wednesday, for: eventA),
                       "a full run already writes every day's media, so a day run "
                       + "beside it is a second writer on the same files")
        XCTAssertTrue(state.regeneratingDays(for: eventA).isEmpty,
                      "a refused claim must not record the day as running, or the "
                      + "spinner outlives a run nobody started")
    }

    func testAFullRunIsRefusedWhileAnyDayIsRegenerating() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginDay(.wednesday, for: eventA))

        XCTAssertFalse(state.beginFullRun(eventA),
                       "a full run writes the day already being written")
        XCTAssertFalse(state.isRunningFull(eventA),
                       "a refused full run must not record itself as running")
    }

    /// The exclusion is per event, like every other rule here.
    func testAFullRunOnOneEventDoesNotBlockADayOnAnother() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginFullRun(eventA))

        XCTAssertTrue(state.beginDay(.wednesday, for: eventB),
                      "two events write different folders and different progress files")
    }

    /// Cover runs stay OUTSIDE this rule, deliberately (#141).
    ///
    /// A cover regeneration must never look like, or trigger, a full reel or
    /// story regen, which is why `isBusy` has never counted them. Folding them
    /// into the exclusion here would make a cover refresh block a rebuild and
    /// vice versa, which is a behaviour change nobody asked for and the opposite
    /// of what #141 established.
    func testACoverRegenIsNotBlockedByAFullRunAndDoesNotBlockOne() {
        var state = PreviewRunState()
        XCTAssertTrue(state.beginFullRun(eventA))
        XCTAssertTrue(state.beginCover(.thursday, for: eventA),
                      "a cover refresh is not a media run and never was")

        var other = PreviewRunState()
        XCTAssertTrue(other.beginCover(.thursday, for: eventA))
        XCTAssertTrue(other.beginFullRun(eventA),
                      "an in flight cover refresh must not block a rebuild")
    }

    /// Ending the blocker releases the block, in both directions.
    func testEachClaimBecomesAvailableAgainWhenTheOtherEnds() {
        var state = PreviewRunState()
        _ = state.beginFullRun(eventA)
        state.endFullRun(eventA)
        XCTAssertTrue(state.beginDay(.wednesday, for: eventA),
                      "the full run is over, so a day run is free to start")

        state.endDay(.wednesday, for: eventA)
        XCTAssertTrue(state.beginFullRun(eventA),
                      "the last day run ended, so a full run is free to start")
    }

    func testASecondFullRunForTheSameEventIsRefused() {
        var state = PreviewRunState()

        XCTAssertTrue(state.beginFullRun(eventA), "first start is allowed")
        XCTAssertFalse(state.beginFullRun(eventA), "a remount must not start a second writer")
        XCTAssertTrue(state.isRunningFull(eventA))
    }

    func testAnotherEventCanRunAtTheSameTime() {
        var state = PreviewRunState()
        _ = state.beginFullRun(eventA)

        XCTAssertTrue(state.beginFullRun(eventB), "events are independent")
    }

    func testEndingARunLetsTheNextOneStart() {
        var state = PreviewRunState()
        _ = state.beginFullRun(eventA)

        state.endFullRun(eventA)

        XCTAssertFalse(state.isRunningFull(eventA))
        XCTAssertTrue(state.beginFullRun(eventA))
    }

    func testASecondRegenOfTheSameDayIsRefusedButOtherDaysAreNot() {
        var state = PreviewRunState()

        XCTAssertTrue(state.beginDay(.wednesday, for: eventA))
        XCTAssertFalse(state.beginDay(.wednesday, for: eventA))
        XCTAssertTrue(state.beginDay(.thursday, for: eventA))
        XCTAssertEqual(state.regeneratingDays(for: eventA), [.wednesday, .thursday])
    }

    func testEndingADayLeavesTheOthersRunning() {
        var state = PreviewRunState()
        _ = state.beginDay(.wednesday, for: eventA)
        _ = state.beginDay(.thursday, for: eventA)

        state.endDay(.wednesday, for: eventA)

        XCTAssertEqual(state.regeneratingDays(for: eventA), [.thursday])
    }

    func testDaysInFlightAreReportedPerEventNotGlobally() {
        var state = PreviewRunState()
        _ = state.beginDay(.wednesday, for: eventA)

        XCTAssertTrue(state.regeneratingDays(for: eventB).isEmpty)
    }

    func testBusyCoversBothKindsOfRun() {
        var state = PreviewRunState()
        XCTAssertFalse(state.isBusy(eventA))

        _ = state.beginDay(.friday, for: eventA)
        XCTAssertTrue(state.isBusy(eventA), "a per-day regen counts as busy")

        state.endDay(.friday, for: eventA)
        _ = state.beginFullRun(eventA)
        XCTAssertTrue(state.isBusy(eventA))
    }

    // MARK: - The image refresh counter belongs here (#1009)

    /// The counter that makes a rebuilt image actually appear on screen lived
    /// as view state on the caption review screen, written in six places there
    /// and read in one.
    ///
    /// So a redraw driven from any OTHER screen completed successfully and left
    /// the review screen showing the previous collage, with nothing saying so.
    /// A silent stale image after a successful rebuild is worse than a failed
    /// one: the failure at least says something.
    ///
    /// Keyed by EVENT as well as day. As view state it was keyed by day alone
    /// and survived only until the screen remounted, so it could not answer the
    /// question at all once more than one screen could ask it.
    func testAFinishedRedrawBumpsTheVersionForThatDayAndEvent() {
        var state = PreviewRunState()

        XCTAssertEqual(state.graphicVersion(.wednesday, for: eventA), 0,
                       "a day nothing has rebuilt starts at zero")

        state.bumpGraphicVersion(.wednesday, for: eventA)

        XCTAssertEqual(state.graphicVersion(.wednesday, for: eventA), 1)
        XCTAssertEqual(state.graphicVersion(.sunday, for: eventA), 0,
                       "only the day that was redrawn refreshes")
        XCTAssertEqual(state.graphicVersion(.wednesday, for: eventB), 0,
                       "another event's Wednesday is a different image")
    }

    /// Two rebuilds of one day are two refreshes, not one.
    ///
    /// The reader compares the number it last drew against the number now, so a
    /// counter that saturated would leave the second rebuild invisible.
    func testASecondRedrawOfTheSameDayBumpsAgain() {
        var state = PreviewRunState()
        state.bumpGraphicVersion(.thursday, for: eventA)
        state.bumpGraphicVersion(.thursday, for: eventA)

        XCTAssertEqual(state.graphicVersion(.thursday, for: eventA), 2)
    }

    // MARK: - Landing a day redraw (#1010)

    /// What a finished redraw writes back, without a caption run anywhere near
    /// it.
    ///
    /// This is the half of the layout switch that #1010 makes free. A switch
    /// that only changes how many photos a day posts needs its images redrawn
    /// and its caption left exactly alone, so this asserts the caption is
    /// untouched as hard as it asserts the paths are written.
    @MainActor
    func testALandedRedrawWritesTheNewPathsAndLeavesTheCaptionAlone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("redraw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var event = Event(name: "Show", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        event.previewMediaPaths["sunday"] = ["collage": "/old/collage.png"]
        var cap = DayCaption()
        cap.caption = "a caption Dan typed"
        cap.generatedCaption = "what the model wrote"
        var week = WeekGenerationResult()
        week.sunday = cap
        event.weekResult = week

        let state = AppState(events: [event],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)
        let manager = PreviewGraphicsManager()

        manager.applyRedraw(
            PythonBridge.PreviewGenerationResult(
                paths: ["sunday": ["collage": "/new/collage.png"]], errors: [:]),
            days: [.sunday], for: event.id, appState: state)

        let landed = try XCTUnwrap(state.events.first(where: { $0.id == event.id }))
        XCTAssertEqual(landed.previewMediaPaths["sunday"]?["collage"], "/new/collage.png",
                       "the redrawn image has to replace the one it was drawn to replace")
        XCTAssertEqual(landed.weekResult?.sunday?.caption, "a caption Dan typed",
                       "a redraw must not touch the caption, which is the whole point "
                       + "of splitting the two kinds of work")
        XCTAssertEqual(manager.graphicVersion(.sunday, for: event.id), 1,
                       "the screen has to be told to reload the file it already drew")
    }

    /// A day the run failed on keeps its old image and says why.
    ///
    /// Silently leaving the previous graphic while reporting success is the
    /// failure this whole path was built to avoid: the export would then ship
    /// an image built for the layout Dan just moved away from.
    @MainActor
    func testAFailedDayIsRecordedRatherThanQuietlyLeavingTheOldImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("redraw-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var event = Event(name: "Show", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        event.previewMediaPaths["sunday"] = ["collage": "/old/collage.png"]
        let state = AppState(events: [event],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)
        let manager = PreviewGraphicsManager()

        manager.applyRedraw(
            PythonBridge.PreviewGenerationResult(
                paths: [:], errors: ["sunday": "collage failed: too few photos"]),
            days: [.sunday], for: event.id, appState: state)

        XCTAssertNotNil(manager.dayFailure(.sunday, for: event.id),
                        "a day that failed has to say so, or the screen shows the old "
                        + "collage with nothing explaining it")
        XCTAssertEqual(manager.graphicVersion(.sunday, for: event.id), 0,
                       "nothing was redrawn, so nothing should be reloaded")
    }

    // MARK: - The day scoped render driver (#1009)

    /// The whole per day render used to be three private methods on
    /// `CaptionReviewView`, so no other screen could redraw a day's images and
    /// the landing itself could not be tested. These pin what the landing half
    /// does now that it lives here.
    ///
    /// The run that produces the result is deliberately not exercised: it goes
    /// through `PythonBridge.shared`, which has no seam, and what a finished
    /// result MEANS is the half worth testing.

    /// A day that rendered: the new images replace the old, the day's stored
    /// media error goes away because this render had nothing to say, the clip
    /// plan and cover pick that came back are applied, the slot is released,
    /// and the screen is told to reload the file it already drew.
    @MainActor
    func testALandedDayRenderWritesTheImagesAndClearsTheDaysStoredFailure() throws {
        let (event, state) = try eventInAStore { ev in
            ev.previewMediaPaths["friday"] = ["reel": "/old/reel.mp4"]
            ev.mediaErrors["friday"] = "the run before said this day was broken"
            ev.days["friday"] = PostingDay(day: .friday)
        }
        let manager = PreviewGraphicsManager()
        XCTAssertTrue(manager.beginDayRegen(.friday, for: event.id))

        var result = PythonBridge.PreviewGenerationResult(
            paths: ["friday": ["reel": "/new/reel.mp4"]], errors: [:])
        result.fridayClipPlan = FridayClipPlan(selections: [], rationale: "the new cut")
        result.coverPicks["friday"] = CoverPick(sourcePath: "/new/cover.jpg", rationale: "sharpest")

        XCTAssertTrue(manager.applyDayRender(result, day: .friday,
                                             for: event.id, appState: state),
                      "a day that rendered has to report that it landed, because "
                      + "that is what the completion notice is sent on")

        let landed = try XCTUnwrap(state.events.first(where: { $0.id == event.id }))
        XCTAssertEqual(landed.previewMediaPaths["friday"]?["reel"], "/new/reel.mp4",
                       "the new image has to replace the one it was drawn to replace")
        XCTAssertNil(landed.mediaErrors["friday"],
                     "this render had nothing to say about the day, so the reason "
                     + "left by the render before is no longer true (L14)")
        XCTAssertEqual(landed.days["friday"]?.fridayClipPlan?.rationale, "the new cut",
                       "the clip plan the run came back with is part of what it "
                       + "produced, and the review screen reads it")
        XCTAssertEqual(landed.days["friday"]?.coverPick?.sourcePath, "/new/cover.jpg",
                       "the cover pick the run made has to be persisted with it")
        XCTAssertTrue(manager.regeneratingDays(event.id).isEmpty,
                      "a landed render releases its slot, or the day can never be "
                      + "rebuilt again and its spinner runs forever")
        XCTAssertEqual(manager.graphicVersion(.friday, for: event.id), 1,
                       "the screen has to be told to reload the file it already drew")
    }

    /// A landed render records WHICH layout it was drawn under (#1010).
    ///
    /// Without this the export gate has nothing to read: a day whose redraw
    /// failed would be indistinguishable from one drawn under the layout the
    /// event now says, and the stale check would pass everything forever while
    /// looking like an active safeguard (L90).
    @MainActor
    func testALandedRenderRecordsTheLayoutItWasDrawnUnder() throws {
        let (event, state) = try eventInAStore { ev in
            ev.postingPresetOverride = .opening
            var sunday = PostingDay(day: .sunday)
            sunday.photoPaths = (1...7).map { URL(fileURLWithPath: "/photos/\($0).jpg") }
            ev.days["sunday"] = sunday
        }
        let manager = PreviewGraphicsManager()
        XCTAssertTrue(manager.beginDayRegen(.sunday, for: event.id))

        XCTAssertTrue(manager.applyDayRender(
            PythonBridge.PreviewGenerationResult(
                paths: ["sunday": ["collage": "/new/collage.png"]], errors: [:]),
            day: .sunday, for: event.id, appState: state))

        let landed = try XCTUnwrap(state.events.first(where: { $0.id == event.id }))
        XCTAssertEqual(landed.days["sunday"]?.renderedPostingPreset, .opening,
                       "nothing recorded what these images were drawn for, so no "
                       + "later switch can tell a day it moved past from one it "
                       + "never touched")
    }

    /// A day that FAILED keeps whatever layout its existing images were drawn
    /// under, because they are still the images on disk.
    @MainActor
    func testAFailedRenderDoesNotClaimTheDayWasDrawnForTheNewLayout() throws {
        let (event, state) = try eventInAStore { ev in
            ev.postingPresetOverride = .opening
            var sunday = PostingDay(day: .sunday)
            sunday.photoPaths = (1...7).map { URL(fileURLWithPath: "/photos/\($0).jpg") }
            sunday.renderedPostingPreset = .balanced
            ev.days["sunday"] = sunday
        }
        let manager = PreviewGraphicsManager()
        XCTAssertTrue(manager.beginDayRegen(.sunday, for: event.id))

        XCTAssertFalse(manager.applyDayRender(
            PythonBridge.PreviewGenerationResult(
                paths: [:], errors: ["sunday": "collage failed: too few photos"]),
            day: .sunday, for: event.id, appState: state))

        let landed = try XCTUnwrap(state.events.first(where: { $0.id == event.id }))
        XCTAssertEqual(landed.days["sunday"]?.renderedPostingPreset, .balanced,
                       "the images on disk are still the old layout's, so recording "
                       + "the new one here would tell the export gate a switch "
                       + "landed that never did")
        XCTAssertEqual(ExportReadiness.blockedReason(for: landed, preset: .opening,
                                                     regeneratingDays: []),
                       "Redraw Sunday",
                       "and the export has to refuse the day, which is the whole "
                       + "reason the layout is recorded at all")
    }

    /// A day the PIPELINE reported an error for keeps the marker it reported.
    ///
    /// `generate_media.py` prefixes the cases it has a remedy for, and Friday's
    /// "< 3 usable clips" escape hatch is reached FROM the recorded failure, so
    /// wrapping the marker into prose and recording only the wrapping leaves the
    /// one failure with a way out shown without it (#730).
    @MainActor
    func testAPipelineErrorIsRecordedWithTheMarkerTheCardDecidesFrom() throws {
        let (event, state) = try eventInAStore { ev in
            ev.previewMediaPaths["friday"] = ["reel": "/old/reel.mp4"]
        }
        let manager = PreviewGraphicsManager()
        XCTAssertTrue(manager.beginDayRegen(.friday, for: event.id))

        XCTAssertFalse(manager.applyDayRender(
            PythonBridge.PreviewGenerationResult(
                paths: [:], errors: ["friday": "insufficient_clips: only 2 usable"]),
            day: .friday, for: event.id, appState: state),
            "a day that failed did not land, so nothing may announce it as ready")

        let failure = try XCTUnwrap(manager.dayFailure(.friday, for: event.id))
        XCTAssertEqual(failure.pipelineError, "insufficient_clips: only 2 usable",
                       "the pipeline's own text has to survive to the card that "
                       + "offers the remedy, not just the sentence wrapped round it")
        let landed = try XCTUnwrap(state.events.first(where: { $0.id == event.id }))
        XCTAssertEqual(landed.mediaErrors["friday"], "insufficient_clips: only 2 usable",
                       "the asset screen reads the event, so a day that failed here "
                       + "must not look fine over there")
        XCTAssertEqual(landed.previewMediaPaths["friday"]?["reel"], "/old/reel.mp4",
                       "a failed render must not take away the image it did not replace")
        XCTAssertEqual(manager.graphicVersion(.friday, for: event.id), 0,
                       "nothing was redrawn, so nothing should be reloaded")
    }

    /// Python exiting zero having written nothing for the day is its own
    /// failure with its own sentence, not a pipeline error (L11).
    @MainActor
    func testADayWithNoOutputAtAllFailsWithItsOwnSentence() throws {
        let (event, state) = try eventInAStore { _ in }
        let manager = PreviewGraphicsManager()
        XCTAssertTrue(manager.beginDayRegen(.wednesday, for: event.id))

        XCTAssertFalse(manager.applyDayRender(
            PythonBridge.PreviewGenerationResult(paths: [:], errors: [:]),
            day: .wednesday, for: event.id, appState: state),
            "a run that produced no output did not land")

        let failure = try XCTUnwrap(manager.dayFailure(.wednesday, for: event.id))
        XCTAssertNil(failure.pipelineError,
                     "there was no pipeline error to keep, and a marker invented "
                     + "here would send the card looking for a remedy that does "
                     + "not exist")
        XCTAssertTrue(failure.reason.contains("no output"),
                      "produced nothing is a different sentence from reported an "
                      + "error, and Dan reads this one")
        XCTAssertTrue(manager.regeneratingDays(event.id).isEmpty,
                      "a failure releases the slot too, or the day is stuck")
    }

    /// The event was deleted while its render was in flight.
    ///
    /// There is nothing to write it onto, so the only thing that matters is that
    /// the day does not keep a spinner for work that has already stopped (L110).
    @MainActor
    func testALandingOnAnEventThatWentAwayReleasesTheDayRatherThanSpinning() throws {
        let (event, state) = try eventInAStore { _ in }
        let manager = PreviewGraphicsManager()
        XCTAssertTrue(manager.beginDayRegen(.sunday, for: event.id))
        state.events.removeAll { $0.id == event.id }

        XCTAssertFalse(manager.applyDayRender(
            PythonBridge.PreviewGenerationResult(
                paths: ["sunday": ["collage": "/new/collage.png"]], errors: [:]),
            day: .sunday, for: event.id, appState: state),
            "there is no event to land on, so nothing landed")

        XCTAssertTrue(manager.regeneratingDays(event.id).isEmpty,
                      "the slot has to be released, or that day shows a spinner "
                      + "for a run that already finished")
        XCTAssertEqual(manager.graphicVersion(.sunday, for: event.id), 0,
                       "nothing was written, so nothing should be reloaded")
    }

    /// The run has to be built from the event as it stands AFTER the caller's
    /// write, not as it stood when the slot was claimed (#1010).
    ///
    /// The claim is deliberately taken FIRST, so a refusal costs nothing and
    /// leaves nothing to undo (L197, L5). That ordering is exactly what makes a
    /// snapshot taken at claim time wrong: it still carries the layout the
    /// switch is moving AWAY from, and the manifest handed to Python carries
    /// `effectivePostingPreset`. A Balanced to Opening switch on a Sunday with
    /// seven photos would redraw it at four again, land the identical images,
    /// bump the version, and report a finished switch that changed nothing.
    @MainActor
    func testARedrawRendersTheLayoutTheSwitchMovedToNotTheOneItLeft() async throws {
        let (event, state) = try eventInAStore { ev in
            ev.postingPresetOverride = .balanced
            var sunday = PostingDay(day: .sunday)
            sunday.photoPaths = (1...7).map { URL(fileURLWithPath: "/photos/\($0).jpg") }
            ev.days["sunday"] = sunday
        }
        let manager = PreviewGraphicsManager()
        let handed = HandedEvent()
        manager.renderPreview = { rendering, _ in
            await handed.record(rendering)
            return PythonBridge.PreviewGenerationResult(
                paths: ["sunday": ["collage": "/new/collage.png"]], errors: [:])
        }

        XCTAssertTrue(manager.startRedraw([.sunday], for: event.id, appState: state))
        // What the layout control does next, in this same main actor turn: the
        // claim was granted, so the switch is written.
        var switched = try XCTUnwrap(state.events.first(where: { $0.id == event.id }))
        switched.postingPresetOverride = .opening
        state.updateEvent(switched)

        await Self.waitUntil("the redraw never started") { await handed.value != nil }
        let seen = await handed.value
        let rendered = try XCTUnwrap(seen)
        XCTAssertEqual(rendered.postingPresetOverride, .opening,
                       "the run was built from the event as it stood at claim time, "
                       + "which still carries the layout being left, so it redraws "
                       + "the images it was started to replace")
    }

    /// A redraw whose run DIED leaves every day it claimed flagged, not
    /// spinning (#1010).
    ///
    /// A run that throws reports nothing per day, so nothing else can release
    /// the slots it took. The positive case is in the same fixture (the run is
    /// reached at all, which the refusal case could not tell apart from a claim
    /// that never happened) and the negative is what this pins: a spinner over
    /// dead work is indistinguishable from slow work and never ends (L110, L159).
    @MainActor
    func testARedrawRunThatDiedFlagsEveryDayItClaimed() async throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "ffmpeg is not installed" }
        }
        let (event, state) = try eventInAStore { ev in
            ev.previewMediaPaths["sunday"] = ["collage": "/old/collage.png"]
        }
        let manager = PreviewGraphicsManager()
        let reached = HandedEvent()
        manager.renderPreview = { rendering, _ in
            await reached.record(rendering)
            throw Refused()
        }

        XCTAssertTrue(manager.startRedraw([.sunday, .monday], for: event.id, appState: state))
        await Self.waitUntil("the run was never reached") { await reached.value != nil }
        await Self.waitUntil("the days were never released") {
            await MainActor.run { manager.regeneratingDays(event.id).isEmpty }
        }

        for day in [DayName.sunday, .monday] {
            let failure = try XCTUnwrap(manager.dayFailure(day, for: event.id),
                                        "\(day.displayName) kept a spinner for a run "
                                        + "that had already died")
            XCTAssertTrue(failure.reason.contains("ffmpeg is not installed"),
                          "the reason has to name what went wrong, not just that "
                          + "something did: \(failure.reason)")
        }
        let landed = try XCTUnwrap(state.events.first(where: { $0.id == event.id }))
        XCTAssertEqual(landed.previewMediaPaths["sunday"]?["collage"], "/old/collage.png",
                       "a run that died must not take away the image it never replaced")
    }

    /// The event this manager was asked to render, as the run actually saw it.
    private actor HandedEvent {
        private(set) var value: Event?
        func record(_ event: Event) { value = event }
    }

    /// Wait for a condition rather than for a fixed time.
    ///
    /// A fixed sleep asserts about what else the machine is running and pays its
    /// whole cost on every green run; this returns the moment the condition
    /// holds (L290, L224).
    private static func waitUntil(_ message: String,
                           timeout: Duration = .seconds(5),
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           until condition: @Sendable () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(message, file: file, line: line)
    }

    /// One event in a real store on disk, so the write-back path under test is
    /// the one the app runs rather than a stub of it.
    @MainActor
    private func eventInAStore(_ prepare: (inout Event) -> Void) throws -> (Event, AppState) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        var event = Event(name: "Show", org: "Org", venue: "Hall",
                          date: Date(timeIntervalSince1970: 1_700_000_000),
                          shootType: .fullShow)
        prepare(&event)
        return (event, AppState(events: [event],
                                storeURL: root.appendingPathComponent("events.json"),
                                dataRoot: root))
    }
}
