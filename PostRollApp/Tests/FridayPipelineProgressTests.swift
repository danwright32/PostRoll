import XCTest

/// Pins the Friday pipeline's progress state machine (#135): a bare spinner
/// that looks identical whether the run is progressing, hung, or dead is a
/// defect. Elapsed time (not just started/not-started) and a stall
/// threshold that converts an indefinite spinner into a visibly distinct,
/// actionable state are both required.
final class FridayPipelineProgressTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    func testIdleWhenNeverStarted() {
        let state = FridayPipelineProgressState.state(startedAt: nil, now: epoch, failedMessage: nil)
        XCTAssertEqual(state, .idle)
    }

    func testRunningShowsElapsedSecondsSinceStart() {
        let started = epoch
        let now = epoch.addingTimeInterval(12)
        let state = FridayPipelineProgressState.state(startedAt: started, now: now, failedMessage: nil)
        XCTAssertEqual(state, .running(elapsedSeconds: 12))
    }

    func testStalledOnceElapsedReachesThreshold() {
        let started = epoch
        let now = epoch.addingTimeInterval(180)
        let state = FridayPipelineProgressState.state(
            startedAt: started, now: now, failedMessage: nil, stallThreshold: 180
        )
        XCTAssertEqual(state, .stalled(elapsedSeconds: 180))
    }

    func testStillRunningJustBelowThreshold() {
        let started = epoch
        let now = epoch.addingTimeInterval(179)
        let state = FridayPipelineProgressState.state(
            startedAt: started, now: now, failedMessage: nil, stallThreshold: 180
        )
        XCTAssertEqual(state, .running(elapsedSeconds: 179))
    }

    func testFailedMessageWinsRegardlessOfElapsedTime() {
        let state = FridayPipelineProgressState.state(
            startedAt: epoch, now: epoch.addingTimeInterval(5), failedMessage: "clip reel skipped: only 1 usable"
        )
        XCTAssertEqual(state, .failed("clip reel skipped: only 1 usable"))
    }

    func testFailedWinsOverStalled() {
        let state = FridayPipelineProgressState.state(
            startedAt: epoch, now: epoch.addingTimeInterval(999), failedMessage: "ffmpeg crashed"
        )
        XCTAssertEqual(state, .failed("ffmpeg crashed"))
    }
}
