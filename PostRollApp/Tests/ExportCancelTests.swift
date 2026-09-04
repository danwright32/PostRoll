import XCTest

/// #1047: an export that had started could not be stopped.
///
/// Reported by Dan from the export screen on 2026-08-30, mid run on Battery
/// Dance Festival. The screen showed a spinner, an elapsed clock against an
/// estimate (0:25 / ~2:42), and one button: "Skip, text export only". That
/// button is not a cancel. It carries on with the export, just with less in it.
/// So a run started by mistake, the wrong show or the wrong photo selection,
/// left two ways out: wait nearly three minutes for work that was going to be
/// thrown away, or quit the app.
///
/// ## The three states
///
/// Running, winding down, and stopped have to be tellable apart, on the pane
/// and on the sidebar pill at once. The subprocess takes a moment to die, so a
/// screen that jumps from the spinner straight to "cancelled" claims ffmpeg has
/// exited before it has, and a sidebar still saying "Exporting…" over a pane
/// saying "Cancelling…" is the same contradiction #182 was filed about (L53).
///
/// ## What is NOT tested here
///
/// That SIGTERM reaches the subprocess tree. `ProcessRunnerTests
/// .testCancellingTheTaskTerminatesTheChild` owns that against a real child,
/// and repeating it here would be a second, weaker copy. What IS tested here is
/// the link between the button and that machinery, which is the half nothing
/// else covers.
@MainActor
final class ExportCancelTests: XCTestCase {

    private var destination: URL!

    override func setUp() async throws {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: destination)
    }

    private func generating() -> (ExportManager, UUID) {
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .generatingMedia(destination), for: id)
        return (manager, id)
    }

    // MARK: - Cancel is not skip

    func testCancellingPutsTheRunIntoItsOwnWindingDownState() {
        let (manager, id) = generating()

        XCTAssertTrue(manager.cancel(eventID: id))

        guard case .cancelling? = manager.run(for: id)?.phase else {
            return XCTFail("cancel must be visible the instant it is accepted, "
                           + "and as its own state rather than as the spinner "
                           + "it replaces")
        }
    }

    func testCancellingIsNotSkipping() {
        // The two buttons sit beside each other and mean opposite things. Skip
        // deliberately keeps the media step running so the milestone is still
        // stamped; cancel throws the run away.
        let (manager, id) = generating()

        manager.cancel(eventID: id)

        XCTAssertFalse(manager.isFinishingMedia(id),
                       "a cancelled run is not finishing anything in the "
                       + "background, which is exactly what skip does")
        if case .done? = manager.run(for: id)?.phase {
            XCTFail("cancel must not show the export complete screen")
        }
    }

    func testTheRunStaysInFlightWhileItWindsDown() {
        // Deactivating here would let a second export start against a folder
        // the dying run is still writing into.
        let (manager, id) = generating()

        manager.cancel(eventID: id)

        XCTAssertTrue(manager.isExporting(id),
                      "the work has not stopped yet, so the app must still "
                      + "consider it in flight")
        XCTAssertTrue(manager.hasWorkInFlight,
                      "and the app must not offer to update itself and quit "
                      + "over a run that is still tearing down (#686)")
    }

    func testTheSidebarSaysCancellingRatherThanExporting() {
        // Both are true at once while it winds down, and the pill takes the
        // more recent of the two, or it contradicts the pane (#182, L53).
        let (manager, id) = generating()
        manager.cancel(eventID: id)

        let pill = StagePillState.resolve(
            stage: .exported, isGenerating: false, generationFailed: false,
            isExporting: manager.isExporting(id),
            isCancellingExport: manager.isCancelling(id),
            isFinishingMedia: manager.isFinishingMedia(id),
            awaitingGeneration: false, awaitingExport: false)

        XCTAssertEqual(pill, .cancellingExport)
        XCTAssertEqual(pill.label, "Cancelling…")
        XCTAssertTrue(pill.isBusy,
                      "the dot keeps pulsing: the subprocess is still dying")
    }

    // MARK: - It has to reach the work

    func testCancellingCancelsTheTaskDoingTheWork() async {
        // The phase is the cheap half. This is the half that matters: a screen
        // saying "Cancelling…" over an ffmpeg still running would be worse than
        // no button at all, because the machine stays busy and the next run
        // competes with it.
        let (manager, id) = generating()
        let reachedTheEnd = expectation(description: "the work ran to completion")
        reachedTheEnd.isInverted = true

        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
                reachedTheEnd.fulfill()
            } catch {
                // Cancelled, which is the pass.
            }
        }
        manager.setTaskForTesting(task, for: id)

        manager.cancel(eventID: id)

        await fulfillment(of: [reachedTheEnd], timeout: 1.0)
        XCTAssertTrue(task.isCancelled,
                      "cancel changed the phase without reaching the work")
    }

    // MARK: - Pressing twice, and pressing too late

    func testPressingCancelTwiceDoesNothingTheSecondTime() {
        let (manager, id) = generating()

        XCTAssertTrue(manager.cancel(eventID: id))
        XCTAssertFalse(manager.cancel(eventID: id),
                       "a second press must not be reported as a second cancel")
        guard case .cancelling? = manager.run(for: id)?.phase else {
            return XCTFail("and it must leave the winding down state alone")
        }
    }

    func testCancellingAFinishedExportDoesNothing() {
        // The press landed a moment after the run completed. The folder is
        // written; there is nothing left to stop, and the done screen must not
        // be replaced by a cancelling spinner for work that is over (L109).
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .done(destination, mediaError: nil,
                                              mediaWarning: nil), for: id)
        manager.deactivateForTesting(id)

        XCTAssertFalse(manager.cancel(eventID: id))
        guard case .done? = manager.run(for: id)?.phase else {
            return XCTFail("the done screen must stay up")
        }
    }

    func testCancellingAFailedExportDoesNothing() {
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .failed("disk full"), for: id)
        manager.deactivateForTesting(id)

        XCTAssertFalse(manager.cancel(eventID: id))
    }

    func testCancellingWhenNothingIsRunningDoesNothing() {
        let manager = ExportManager()

        XCTAssertFalse(manager.cancel(eventID: UUID()))
    }

    func testTheTextExportPhaseCanAlsoBeCancelled() {
        // The first phase is fast, but "fast" is not "instant", and a text
        // export against a slow or unreachable volume is exactly when somebody
        // wants out (L101).
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .exportingText, for: id)

        XCTAssertTrue(manager.cancel(eventID: id))
    }

    // MARK: - Once it has actually stopped

    func testTheSidebarStopsSayingCancellingOnceTheRunIsOver() {
        // `cancelRequested` stays true through a cancel the commit beat, so
        // asking that flag rather than the phase would leave the pill saying
        // "Cancelling…" over a finished export forever (L144).
        let (manager, id) = generating()
        manager.cancel(eventID: id)
        manager.setRunForTesting(phase: .done(destination, mediaError: nil,
                                              mediaWarning: nil), for: id)

        XCTAssertFalse(manager.isCancelling(id))
    }

    // MARK: - What the pipeline does when the work actually stops

    func testTheRunLandsInCancelledOnceTheWorkHasStopped() {
        // The transition the pipeline's CancellationError branch makes. Driven
        // through the method that branch calls, because reaching the branch
        // itself means running a real export against a real folder, and the
        // phase a cancel actually lands in would otherwise never be exercised
        // by anything (L3).
        let (manager, id) = generating()
        manager.cancel(eventID: id)

        manager.finishCancelled(eventID: id)

        guard case .cancelled? = manager.run(for: id)?.phase else {
            return XCTFail("a cancelled run must reach a terminal state rather "
                           + "than sitting in the spinner forever (L110)")
        }
        XCTAssertFalse(manager.isExporting(id),
                       "the work has stopped, so the run is no longer in flight")
        XCTAssertFalse(manager.isCancelling(id),
                       "and the sidebar must stop saying it is winding down")
        XCTAssertFalse(manager.hasWorkInFlight,
                       "and the app may update itself again (#686)")
    }

    func testACancelledRunIsNotStillFinishingMedia() {
        // Cancel can be pressed after Skip, and the media step is genuinely
        // over at this point either way (#182).
        let (manager, id) = generating()
        manager.skipMedia(eventID: id)
        manager.setRunForTesting(phase: .generatingMedia(destination), for: id)
        manager.cancel(eventID: id)

        manager.finishCancelled(eventID: id)

        XCTAssertFalse(manager.isFinishingMedia(id))
    }

    func testACancelledRunCanBeDismissed() {
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .cancelled, for: id)
        manager.deactivateForTesting(id)

        manager.clear(eventID: id)

        XCTAssertNil(manager.run(for: id),
                     "the cancelled screen's own button must return to ready")
    }

    func testACancelledRunIsNotAFailure() {
        // It must not reach the sidebar's "Needs Attention", and it must not
        // be announced as a failure: Dan pressed the button, so telling him the
        // export failed is a claim about something that did not happen (L11).
        let manager = ExportManager()
        let id = UUID()
        manager.setRunForTesting(phase: .cancelled, for: id)
        manager.deactivateForTesting(id)

        XCTAssertFalse(manager.isExporting(id))
        XCTAssertFalse(manager.isFinishingMedia(id))
        if case .failed = manager.run(for: id)?.phase {
            XCTFail("a cancelled run must not present itself as a failure")
        }
    }
}
