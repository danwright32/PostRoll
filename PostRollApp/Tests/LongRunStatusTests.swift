import XCTest

/// #95 and #96: working, still alive, and stalled must be visibly different.
///
/// Blog generation fires five to ten sequential Claude calls, each with a
/// multi-minute timeout, and says nothing in between. Every screen showed the
/// same static spinner throughout, so a run that was progressing, a run that
/// was hung and a run whose process had died were indistinguishable.
///
/// The part worth being careful about is what "stalled" is measured from. A run
/// forty minutes in that reported a step four seconds ago is healthy; a run four
/// minutes in that has said nothing since it started is not. Measuring from the
/// run's total elapsed time gets both of those backwards, so staleness is
/// measured from the last thing the run actually said.
final class LongRunStatusTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func step(_ label: String, secondsAfterStart: Double,
                      index: Int? = nil, total: Int? = nil,
                      done: Bool = false) -> GenerationStep {
        GenerationStep(label: label, index: index, total: total, done: done,
                       updatedAt: start.timeIntervalSince1970 + secondsAfterStart)
    }

    // MARK: - The three states

    func testNoRunIsIdle() {
        XCTAssertEqual(
            LongRunState.status(startedAt: nil, step: nil, now: start),
            .idle)
    }

    func testAFreshRunIsWorkingEvenBeforeItReportsAnything() {
        // The gap between launching Python and its first step is real, and it
        // must not read as stalled.
        let status = LongRunState.status(
            startedAt: start, step: nil, now: start.addingTimeInterval(5))

        XCTAssertEqual(status, .working(elapsedSeconds: 5, step: nil))
    }

    func testTheElapsedTimeIsCounted() {
        guard case .working(let elapsed, _) = LongRunState.status(
            startedAt: start, step: nil, now: start.addingTimeInterval(97))
        else { return XCTFail("expected working") }

        XCTAssertEqual(elapsed, 97)
    }

    func testAFailureAlwaysWins() {
        // A run can fail after it already looked stalled, and the reason is
        // more useful to Dan than the silence.
        let status = LongRunState.status(
            startedAt: start, step: step("Blog", secondsAfterStart: 0),
            now: start.addingTimeInterval(5_000), failedMessage: "ffmpeg died")

        XCTAssertEqual(status, .failed("ffmpeg died"))
    }

    func testAFinishedRunStopsReadingAsInFlight() {
        // Without this the last step sits on screen looking live forever.
        let status = LongRunState.status(
            startedAt: start,
            step: step("", secondsAfterStart: 300, done: true),
            now: start.addingTimeInterval(305))

        XCTAssertEqual(status, .finished)
    }

    // MARK: - Staleness is measured from the last thing the run said

    func testALongRunThatJustReportedIsHealthy() {
        // Forty minutes in, but it spoke four seconds ago. This is the case a
        // total-elapsed threshold would wrongly flag.
        let status = LongRunState.status(
            startedAt: start,
            step: step("Blog: removing AI tells", secondsAfterStart: 2_396),
            now: start.addingTimeInterval(2_400))

        guard case .working = status else {
            return XCTFail("a run that just reported must not read as stalled")
        }
    }

    func testARunThatHasGoneQuietIsStalled() {
        let status = LongRunState.status(
            startedAt: start,
            step: step("Blog: writing the draft", secondsAfterStart: 10),
            now: start.addingTimeInterval(10 + LongRunState.defaultSilenceThreshold + 1))

        guard case .stalled = status else {
            return XCTFail("silence past the threshold must be visible")
        }
    }

    func testAStalledRunStillShowsWhatItWasDoing() {
        // "Something is stuck" is not actionable. Which pass it died in is.
        let status = LongRunState.status(
            startedAt: start,
            step: step("Blog: checking it sounds like you", secondsAfterStart: 10),
            now: start.addingTimeInterval(5_000))

        guard case .stalled(_, let carried) = status else {
            return XCTFail("expected stalled")
        }
        XCTAssertEqual(carried?.label, "Blog: checking it sounds like you")
    }

    func testAnOrdinaryBlogPassDoesNotTripTheThreshold() {
        // A single pass is one Claude call with a 600 second timeout. A
        // threshold under that would flag every ordinary run, and an alert that
        // cries wolf gets ignored.
        XCTAssertGreaterThan(LongRunState.defaultSilenceThreshold, 600)
    }

    func testANewStepClearsAStall() {
        // The run recovering must be visible too, not just the stall.
        let stalled = LongRunState.status(
            startedAt: start, step: step("Sunday", secondsAfterStart: 0),
            now: start.addingTimeInterval(5_000))
        let recovered = LongRunState.status(
            startedAt: start, step: step("Monday", secondsAfterStart: 4_999),
            now: start.addingTimeInterval(5_000))

        guard case .stalled = stalled else { return XCTFail("expected stalled") }
        guard case .working = recovered else { return XCTFail("expected working") }
    }

    // MARK: - What Dan reads

    func testTheStepSaysWhereItIsInTheRun() {
        let s = GenerationStep(label: "Writing the Sunday caption",
                               index: 2, total: 7, updatedAt: 1)

        XCTAssertEqual(s.display, "Writing the Sunday caption (2 of 7)")
    }

    func testAStepWithNoCountIsJustItsLabel() {
        let s = GenerationStep(label: "Blog: removing AI tells", updatedAt: 1)

        XCTAssertEqual(s.display, "Blog: removing AI tells")
    }

    // MARK: - Reading the file Python writes

    func testAStepIsDecodedFromWhatPythonWrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("progress.json")
        try Data("""
        {"label": "Writing the blog post", "index": 7, "total": 7,
         "done": false, "updated_at": 1000010.5}
        """.utf8).write(to: url)

        let step = LongRunState.readStep(at: url)

        XCTAssertEqual(step?.label, "Writing the blog post")
        XCTAssertEqual(step?.index, 7)
        XCTAssertEqual(step?.updatedAt, 1000010.5)
    }

    func testAMissingFileReadsAsNothing() {
        // Polled on a timer, including before the run has written anything.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-written-\(UUID().uuidString).json")

        XCTAssertNil(LongRunState.readStep(at: url))
    }

    func testAHalfWrittenFileReadsAsNothingRatherThanGarbage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("progress.json")
        try Data(#"{"label": "Blog pa"#.utf8).write(to: url)

        XCTAssertNil(LongRunState.readStep(at: url))
    }
}
