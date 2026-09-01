import XCTest

/// #1164: the retry indicator's estimate is measured, and it scales.
///
/// The control shipped with `estimate: "~1 min"`, a number that was chosen and
/// not measured, sitting beside `CALL_TIMEOUT` in `postroll/ai/blog_repair.py`
/// which carries the reading it came from. An unmeasured constant beside
/// measured ones reads as one of them.
///
/// It matters because the estimate is one of the three states
/// `LongRunIndicator` exists to separate (#95, #96): started, still alive,
/// stalled. A retry of five markers judged against an estimate written for one
/// makes a healthy run look stalled, which is the thing the indicator was built
/// to prevent.
///
/// The readings live in `tests/fixtures/alt_text_call_timing.json`, written by
/// `tools/measure_alt_text_call.py`. Both languages consume that one committed
/// file rather than each carrying its own copy of the number (L26, L41).
final class RepairRetryEstimateTests: XCTestCase {

    private struct Timing: Decodable {
        struct Reading: Decodable {
            let measured_on: String
            let seconds: Double
            let answered: Bool
        }
        let readings: [Reading]
    }

    private func recordedReadings() throws -> [Timing.Reading] {
        let timing = try JSONDecoder().decode(
            Timing.self,
            from: try RepoFixture.data("tests/fixtures/alt_text_call_timing.json"))
        // Only calls that ANSWERED timed the work; one that returned nothing
        // timed the failure (L331), and `summarise` in the measuring tool drops
        // them for the same reason.
        let answered = timing.readings.filter { $0.answered }
        XCTAssertGreaterThanOrEqual(
            answered.count, 3,
            "fewer than three answered readings: the estimate would be derived "
            + "from a sample too small to have a slowest, and a gutted fixture "
            + "would pass every assertion below vacuously")
        return answered
    }

    // --- the defect the issue names ----------------------------------------

    func testFiveMarkersAreNotEstimatedTheSameAsOne() {
        guard let one = RepairRetryEstimate.bounds(markerCount: 1),
              let five = RepairRetryEstimate.bounds(markerCount: 5) else {
            return XCTFail("no estimate for a retry that has markers to retry")
        }

        XCTAssertGreaterThan(
            five.upperBound, one.upperBound,
            "five markers carry the same estimate as one, so a healthy "
            + "five-marker retry is judged against a number written for a "
            + "one-marker run and reads as stalled")
    }

    func testTheEstimateGrowsInStepWithTheMarkerCount() {
        // Not merely "bigger": the work is one call per marker per round, so
        // ten markers is ten times the calls, and an estimate that grew by a
        // token amount would pass the test above while still understating.
        guard let one = RepairRetryEstimate.bounds(markerCount: 1),
              let ten = RepairRetryEstimate.bounds(markerCount: 10) else {
            return XCTFail("no estimate for a retry that has markers to retry")
        }

        XCTAssertGreaterThan(
            ten.upperBound, one.upperBound * 5,
            "ten markers is ten times the model calls of one, but the estimate "
            + "barely moved, so it is still effectively a constant")
    }

    // --- it is derived from the readings, not from a chosen number ---------

    func testTheUpperBoundCoversTheMeasuredWorstCase() throws {
        let slowest = try recordedReadings().map(\.seconds).max()!

        for markers in [1, 3, 5, 7] {
            guard let bounds = RepairRetryEstimate.bounds(markerCount: markers) else {
                return XCTFail("no estimate for \(markers) markers")
            }
            // Every marker needing both rounds is the worst the pass can do:
            // `MAX_ROUNDS` calls apiece, each as slow as the slowest reading.
            let worstCase = slowest * Double(RepairRetryEstimate.roundsPerMarker)
                * Double(markers)
            XCTAssertGreaterThanOrEqual(
                bounds.upperBound, worstCase,
                "the estimate for \(markers) markers tops out below what the "
                + "measured worst case costs, so the run outlives its own "
                + "estimate and looks stalled while healthy")
        }
    }

    func testTheLowerBoundIsNotSlowerThanTheFastestMeasuredRun() throws {
        let fastest = try recordedReadings().map(\.seconds).min()!

        guard let bounds = RepairRetryEstimate.bounds(markerCount: 4) else {
            return XCTFail("no estimate for 4 markers")
        }
        // Best case is every marker fixed on its first round.
        let bestCase = fastest * 4
        XCTAssertLessThanOrEqual(
            bounds.lowerBound, bestCase + RepairRetryEstimate.startupSeconds,
            "the floor of the estimate is above what a clean run actually "
            + "costs, so the fastest possible retry still reads as behind")
    }

    func testThePerCallCostIsTheRecordedSlowestReading() throws {
        let slowest = try recordedReadings().map(\.seconds).max()!

        XCTAssertEqual(
            RepairRetryEstimate.slowestCallSeconds, slowest, accuracy: 0.001,
            "the estimate's per-call cost has drifted from "
            + "tests/fixtures/alt_text_call_timing.json. Re-run "
            + "tools/measure_alt_text_call.py and derive it again rather than "
            + "editing the constant, or this becomes another chosen number")
    }

    func testTheFastestCostIsTheRecordedFastestReading() throws {
        let fastest = try recordedReadings().map(\.seconds).min()!

        XCTAssertEqual(
            RepairRetryEstimate.fastestCallSeconds, fastest, accuracy: 0.001,
            "the floor of the estimate has drifted from "
            + "tests/fixtures/alt_text_call_timing.json, so the range no longer "
            + "describes the calls that were actually timed")
    }

    func testTheRoundBudgetIsTheOneTheRepairPassActuallyUses() throws {
        // The Python side owns MAX_ROUNDS. If it moves and this does not, the
        // estimate silently describes a different amount of work (L41).
        let source = try String(
            contentsOf: RepoFixture.repoRoot()
                .appendingPathComponent("postroll/ai/blog_repair.py"),
            encoding: .utf8)
        let match = source.range(of: #"(?m)^MAX_ROUNDS = (\d+)"#,
                                 options: .regularExpression)
        guard let match else {
            return XCTFail("MAX_ROUNDS is no longer declared where this reads it")
        }
        let rounds = Int(source[match].replacingOccurrences(
            of: "MAX_ROUNDS = ", with: ""))!

        XCTAssertEqual(
            RepairRetryEstimate.roundsPerMarker, rounds,
            "the repair pass makes \(rounds) attempts per marker and the "
            + "estimate is built on \(RepairRetryEstimate.roundsPerMarker)")
    }

    // --- nothing to retry has no estimate, rather than a wrong one ---------

    func testThereIsNoEstimateWhenThereIsNothingToRetry() {
        XCTAssertNil(RepairRetryEstimate.bounds(markerCount: 0),
                     "an estimate for a retry of nothing is a number about "
                     + "work that will not happen")
        XCTAssertNil(RepairRetryEstimate.text(markerCount: 0))
    }

    // --- the wording ------------------------------------------------------

    func testTheWordingNamesBothEndsAndItsUnit() {
        guard let text = RepairRetryEstimate.text(markerCount: 5) else {
            return XCTFail("no estimate text for 5 markers")
        }
        XCTAssertTrue(text.contains("to"),
                      "a single number reads as a promise; the readings give a "
                      + "range and the wording should say so: \(text)")
        XCTAssertTrue(text.contains("sec") || text.contains("min"),
                      "the estimate names no unit: \(text)")
    }

    func testAOneMarkerRetryIsNotDescribedInMinutes() {
        // The measured cost of one marker is single-figure seconds. "~1 min"
        // was the shipped constant, and against it a five second run spends
        // most of its life looking behind schedule.
        guard let text = RepairRetryEstimate.text(markerCount: 1) else {
            return XCTFail("no estimate text for 1 marker")
        }
        XCTAssertTrue(text.contains("sec"),
                      "one marker costs seconds by measurement but is "
                      + "advertised as \(text)")
    }

    // --- the panel uses it, rather than carrying its own number ------------

    func testTheRetryIndicatorTakesItsEstimateFromHere() throws {
        // The whole defect was a literal at the call site. A constant put back
        // there would leave every assertion above passing while the panel again
        // showed a number nobody measured (L135, L280).
        let source = try String(
            contentsOf: RepoFixture.repoRoot()
                .appendingPathComponent(
                    "PostRollApp/Sources/Views/CaptionReview/BlogSection.swift"),
            encoding: .utf8)

        guard let run = source.range(of: "run: .blogRetry") else {
            return XCTFail("the retry indicator is no longer declared where "
                           + "this reads it")
        }
        // The estimate argument sits with the run it belongs to.
        let rest = source[run.lowerBound...]
        let window = String(rest.prefix(400))
        guard let estimate = window.range(of: "estimate:") else {
            return XCTFail("the retry indicator no longer passes an estimate, "
                           + "so the run shows elapsed time with nothing to "
                           + "judge it against")
        }
        let argument = String(window[estimate.upperBound...].prefix(80))
        XCTAssertTrue(
            argument.contains("RepairRetryEstimate"),
            "the retry indicator's estimate is written at the call site rather "
            + "than derived from the readings: \(argument)")
    }
}
