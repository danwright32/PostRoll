import XCTest

/// Pins the bookkeeping shared by GenerationManager / OCRManager / ExportManager.
/// The key invariant behind the "switching events loses progress" fix: jobs are
/// tracked independently per event id, and the active/failed membership sets
/// stay correct across every transition so the sidebar reads them reliably.
@MainActor
final class JobTrackerTests: XCTestCase {

    private struct Job: Equatable {
        var elapsedSeconds: Int = 0
        var label: String = ""
        /// The handle on the work. `JobTracker` requires one now, because an
        /// owner that could leave it out would show a spinner with no way back
        /// (#1050).
        var task: Task<Void, Never>?

        static func == (a: Job, b: Job) -> Bool {
            a.elapsedSeconds == b.elapsedSeconds && a.label == b.label
        }
    }

    private func makeTracker() -> JobTracker<UUID, Job> {
        JobTracker<UUID, Job>(elapsed: \.elapsedSeconds, task: \.task)
    }

    /// Work that never finishes on its own, so the only way it ends is a stop.
    private func neverEnds() -> Task<Void, Never> {
        Task { try? await Task.sleep(for: .seconds(30)) }
    }

    func testBeginMarksActiveAndStoresJob() {
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a"), for: id)
        XCTAssertTrue(t.isActive(id))
        XCTAssertFalse(t.hasFailed(id))
        XCTAssertEqual(t.job(for: id)?.label, "a")
    }

    func testJobsAreIndependentPerEvent() {
        let t = makeTracker()
        let a = UUID(), b = UUID()
        t.begin(Job(label: "a"), for: a)
        t.begin(Job(label: "b"), for: b)
        // Removing one must not disturb the other — the heart of the fix.
        t.remove(a)
        XCTAssertFalse(t.isActive(a))
        XCTAssertNil(t.job(for: a))
        XCTAssertTrue(t.isActive(b))
        XCTAssertEqual(t.job(for: b)?.label, "b")
    }

    func testUpdateMutatesInPlace() {
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "x"), for: id)
        t.update(id) { $0.label = "y" }
        XCTAssertEqual(t.job(for: id)?.label, "y")
    }

    func testUpdateOnMissingJobIsNoOp() {
        let t = makeTracker()
        t.update(UUID()) { $0.label = "z" }  // must not crash
    }

    func testMarkFailedKeepsJobButClearsActive() {
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "f"), for: id)
        t.update(id) { $0.label = "boom" }
        t.markFailed(id)
        XCTAssertFalse(t.isActive(id))
        XCTAssertTrue(t.hasFailed(id))
        XCTAssertEqual(t.job(for: id)?.label, "boom", "failed job is kept so its message survives")
    }

    func testDeactivateKeepsJob() {
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(), for: id)
        t.deactivate(id)
        XCTAssertFalse(t.isActive(id))
        XCTAssertFalse(t.hasFailed(id))
        XCTAssertNotNil(t.job(for: id), "deactivated (e.g. export .done) job stays for the view")
    }

    func testBeginClearsPriorFailedFlag() {
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(), for: id)
        t.markFailed(id)
        XCTAssertTrue(t.hasFailed(id))
        t.begin(Job(label: "retry"), for: id)   // restart after a failure
        XCTAssertTrue(t.isActive(id))
        XCTAssertFalse(t.hasFailed(id))
    }

    func testRemoveClearsFailedState() {
        // Pins the escape hatch behind OCRProgressView's error screen "Go Back"
        // button: cancelling out of a failed run (not just an active one) must
        // fully clear the job, or the user is stuck with no way off the screen
        // except deleting the project.
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "f"), for: id)
        t.markFailed(id)
        XCTAssertTrue(t.hasFailed(id))

        t.remove(id)

        XCTAssertNil(t.job(for: id))
        XCTAssertFalse(t.isActive(id))
        XCTAssertFalse(t.hasFailed(id))
    }

    func testClearFailedRemovesOnlyWhenIdle() {
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(), for: id)
        // Active → clearFailed is ignored.
        t.clearFailed(id)
        XCTAssertNotNil(t.job(for: id))
        // Failed → clearFailed drops it.
        t.markFailed(id)
        t.clearFailed(id)
        XCTAssertNil(t.job(for: id))
        XCTAssertFalse(t.hasFailed(id))
    }

    // MARK: - Work that belongs to the app rather than to an event (#718)

    /// The two Insights runs, the CSV import and the report generation, are
    /// not about any event: there is one analytics history and one report, so
    /// there is no event id to key them by.
    private enum AppJob: Hashable { case importCSV, generateReport }

    func testJobsCanBeKeyedBySomethingOtherThanAnEvent() {
        // Without this the Insights screen has to grow a second mechanism
        // beside this one, and the two then drift: the whole reason the rule
        // holds is that there is ONE place a long run's progress, clock and
        // error live.
        let t = JobTracker<AppJob, Job>(elapsed: \.elapsedSeconds, task: \.task)

        t.begin(Job(label: "reading the CSVs"), for: .importCSV)
        t.begin(Job(label: "analysing"), for: .generateReport)

        XCTAssertTrue(t.isActive(.importCSV))
        XCTAssertTrue(t.isActive(.generateReport))
        XCTAssertEqual(t.job(for: .importCSV)?.label, "reading the CSVs")

        // Independent, the same way two events are. An import finishing must
        // not take the analysis with it.
        t.remove(.importCSV)
        XCTAssertFalse(t.isActive(.importCSV))
        XCTAssertTrue(t.isActive(.generateReport))
        XCTAssertEqual(t.job(for: .generateReport)?.label, "analysing")
    }

    func testAFailedAppJobKeepsItsMessage() {
        // The reason this matters on the Insights screen specifically: leaving
        // it and coming back destroyed the view, and with it the only copy of
        // why the analysis failed (L148).
        let t = JobTracker<AppJob, Job>(elapsed: \.elapsedSeconds, task: \.task)
        t.begin(Job(label: "analysing"), for: .generateReport)
        t.update(.generateReport) { $0.label = "the model refused" }
        t.markFailed(.generateReport)

        XCTAssertFalse(t.isActive(.generateReport))
        XCTAssertTrue(t.hasFailed(.generateReport))
        XCTAssertEqual(t.job(for: .generateReport)?.label, "the model refused")
    }

    // MARK: - #1050: stopping, once, here

    func testAskingAJobToStopReachesTheWork() {
        // The half that matters. A tracker that recorded the request and never
        // cancelled the task would leave a screen saying "Stopping..." over an
        // ffmpeg still burning the machine, which is worse than no button.
        let t = makeTracker()
        let id = UUID()
        let work = neverEnds()
        t.begin(Job(label: "a", task: work), for: id)

        XCTAssertTrue(t.requestStop(id))

        XCTAssertTrue(work.isCancelled,
                      "the request was recorded without reaching the work")
    }

    func testAStoppingJobIsStillInFlight() {
        // It has not stopped yet. Deactivating here would let a second run
        // start against whatever the dying one is still writing.
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a", task: neverEnds()), for: id)

        t.requestStop(id)

        XCTAssertTrue(t.isActive(id))
        XCTAssertTrue(t.hasWorkInFlight,
                      "the app must not offer to quit and install over a run "
                      + "that is still tearing down (#686)")
        XCTAssertTrue(t.isStopping(id),
                      "and the screen has to be able to say so, distinctly "
                      + "from both running and stopped")
    }

    func testAskingTwiceIsOnlyOneStop() {
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a", task: neverEnds()), for: id)

        XCTAssertTrue(t.requestStop(id))
        XCTAssertFalse(t.requestStop(id),
                       "a second press must not be reported as a second stop")
    }

    func testAJobThatIsNotRunningCannotBeStopped() {
        // The press landed after the work was already over. There is nothing
        // to stop, and saying otherwise would put a winding down state over a
        // finished run (L109).
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a", task: neverEnds()), for: id)
        t.deactivate(id)

        XCTAssertFalse(t.requestStop(id))
        XCTAssertFalse(t.isStopping(id))
    }

    func testStoppingAJobThatWasNeverStartedDoesNothing() {
        let t = makeTracker()

        XCTAssertFalse(t.requestStop(UUID()))
    }

    func testOnceTheWorkStopsItIsNoLongerWindingDown() {
        // Three states, and this is the transition between the last two. The
        // owner's own completion path calls `deactivate`, because that is
        // where it knows what to leave on screen.
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a", task: neverEnds()), for: id)
        t.requestStop(id)

        t.deactivate(id)

        XCTAssertFalse(t.isStopping(id))
        XCTAssertFalse(t.hasWorkInFlight)
    }

    func testAStoppedRunStillRemembersItWasStopped() {
        // Asked AFTER the work is over, so an outcome screen can say "you
        // stopped this" rather than reporting an ordinary end (L11). It is the
        // same record that answered `isStopping`, not a second flag beside it
        // that could disagree (L53).
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a", task: neverEnds()), for: id)
        t.requestStop(id)
        t.deactivate(id)

        XCTAssertTrue(t.wasStopRequested(id))
        XCTAssertFalse(t.isStopping(id),
                       "the two are different questions and must not collapse "
                       + "into one another")
    }

    func testAJobThatEndedOnItsOwnIsNotReportedAsStopped() {
        // The other direction (L159). Without it, "was it stopped" is
        // satisfied by a tracker that says yes to everything.
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a", task: neverEnds()), for: id)

        t.deactivate(id)

        XCTAssertFalse(t.wasStopRequested(id))
    }

    func testAFreshRunUnderTheSameKeyIsNotBornStopped() {
        // A durable record keyed on something reusable outlives the thing it
        // was about (L186). Left behind, the next run would report itself as
        // cancelled the moment it finished.
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a", task: neverEnds()), for: id)
        t.requestStop(id)
        t.deactivate(id)

        t.begin(Job(label: "b", task: neverEnds()), for: id)

        XCTAssertFalse(t.wasStopRequested(id))
        XCTAssertFalse(t.isStopping(id))
    }

    func testRemovingAJobForgetsThatItWasStopped() {
        let t = makeTracker()
        let id = UUID()
        t.begin(Job(label: "a", task: neverEnds()), for: id)
        t.requestStop(id)

        t.remove(id)

        XCTAssertFalse(t.wasStopRequested(id))
    }

    func testStoppingOneJobLeavesTheOthersAlone() {
        let t = makeTracker()
        let a = UUID(), b = UUID()
        let other = neverEnds()
        t.begin(Job(label: "a", task: neverEnds()), for: a)
        t.begin(Job(label: "b", task: other), for: b)

        t.requestStop(a)

        XCTAssertFalse(t.isStopping(b))
        XCTAssertFalse(other.isCancelled,
                       "stopping one event's work must not touch another's")
    }

}
