import XCTest

/// Pins the bookkeeping shared by GenerationManager / OCRManager / ExportManager.
/// The key invariant behind the "switching events loses progress" fix: jobs are
/// tracked independently per event id, and the active/failed membership sets
/// stay correct across every transition so the sidebar reads them reliably.
@MainActor
final class EventJobTrackerTests: XCTestCase {

    private struct Job: Equatable {
        var elapsedSeconds: Int = 0
        var label: String = ""
    }

    private func makeTracker() -> EventJobTracker<Job> {
        EventJobTracker<Job>(elapsed: \.elapsedSeconds)
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
}
