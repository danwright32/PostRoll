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
    }

    private func makeTracker() -> JobTracker<UUID, Job> {
        JobTracker<UUID, Job>(elapsed: \.elapsedSeconds)
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
        let t = JobTracker<AppJob, Job>(elapsed: \.elapsedSeconds)

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
        let t = JobTracker<AppJob, Job>(elapsed: \.elapsedSeconds)
        t.begin(Job(label: "analysing"), for: .generateReport)
        t.update(.generateReport) { $0.label = "the model refused" }
        t.markFailed(.generateReport)

        XCTAssertFalse(t.isActive(.generateReport))
        XCTAssertTrue(t.hasFailed(.generateReport))
        XCTAssertEqual(t.job(for: .generateReport)?.label, "the model refused")
    }
}
