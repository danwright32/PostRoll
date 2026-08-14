import XCTest

/// #467: "still working" has to be something measured, not something assumed.
///
/// The OCR screen asserted it from the wall clock. The elapsed ticker keeps
/// ticking whether or not the Python process is alive, so a hung read looked
/// exactly like a slow one until the 1800 second watchdog fired, up to thirty
/// minutes later. A message may claim only what its check actually measured
/// (L11), and a liveness signal that proves only its own emitter is alive is
/// worse than none because it actively reassures (L106).
final class OCRProgressTextTests: XCTestCase {

    private func step(_ label: String, index: Int? = nil, total: Int? = nil,
                      at: Double = 1_760_000_000) -> GenerationStep {
        GenerationStep(label: label, index: index, total: total, updatedAt: at)
    }

    // MARK: - The phase label says what the run reported

    func testTheRunsOwnStepIsShown() {
        XCTAssertEqual(
            OCRProgressText.phase(step: step("Reading the program", index: 2, total: 3),
                                  fallback: "Analyzing context…"),
            "Reading the program (2 of 3)")
    }

    /// Before the run has said anything there is nothing measured to show, so
    /// the elapsed-derived guess stands. Honest as a guess; it just cannot be
    /// evidence of anything.
    func testTheGuessStandsUntilTheRunReports() {
        XCTAssertEqual(OCRProgressText.phase(step: nil, fallback: "Analyzing context…"),
                       "Analyzing context…")
    }

    func testAnEmptyStepDoesNotBlankTheLabel() {
        XCTAssertEqual(OCRProgressText.phase(step: step(""), fallback: "Analyzing context…"),
                       "Analyzing context…")
    }

    // MARK: - The footer tells slow from silent

    func testAHealthyRunSaysHowLongItUsuallyTakes() {
        let footer = OCRProgressText.footer(
            status: .working(elapsedSeconds: 30, step: step("Reading the program")),
            estimate: 90, formattedEstimate: "1 to 2 minutes")

        XCTAssertFalse(footer.isStalled)
        XCTAssertTrue(footer.text.contains("1 to 2 minutes"), footer.text)
    }

    /// The whole point: a run that has gone quiet reads differently from one
    /// that is merely taking a while.
    func testASilentRunIsShownAsSilentRatherThanSlow() {
        let footer = OCRProgressText.footer(
            status: .stalled(elapsedSeconds: 900, step: step("Reading the program", index: 2, total: 3)),
            estimate: 90, formattedEstimate: "1 to 2 minutes")

        XCTAssertTrue(footer.isStalled, "a stalled run reassured: \(footer.text)")
        XCTAssertFalse(footer.text.lowercased().contains("still working"),
                       "the message still claims the run is working: \(footer.text)")
    }

    /// Which step it went quiet in is the actionable part.
    func testTheSilentMessageNamesTheStepItStoppedIn() {
        let footer = OCRProgressText.footer(
            status: .stalled(elapsedSeconds: 900,
                             step: step("Reading the program", index: 2, total: 3)),
            estimate: nil, formattedEstimate: nil)

        XCTAssertTrue(footer.text.contains("Reading the program (2 of 3)"), footer.text)
    }

    func testASilentRunThatNeverReportedSaysThat() {
        let footer = OCRProgressText.footer(
            status: .stalled(elapsedSeconds: 900, step: nil),
            estimate: nil, formattedEstimate: nil)

        XCTAssertTrue(footer.isStalled)
        XCTAssertTrue(footer.text.contains("has not reported"), footer.text)
    }

    /// A stalled run may still finish, and the message must not tell Dan to
    /// throw away a paid read that is about to land (L111).
    func testTheSilentMessageDoesNotOrderHimToCancel() {
        let footer = OCRProgressText.footer(
            status: .stalled(elapsedSeconds: 900, step: nil),
            estimate: nil, formattedEstimate: nil)

        XCTAssertTrue(footer.text.contains("may still finish"), footer.text)
    }

    func testAFailedRunShowsItsReason() {
        let footer = OCRProgressText.footer(
            status: .failed("The program pages were too large to send."),
            estimate: 90, formattedEstimate: "1 to 2 minutes")

        XCTAssertTrue(footer.isStalled)
        XCTAssertEqual(footer.text, "The program pages were too large to send.")
    }

    func testWithNoEstimateItStillSaysSomethingUseful() {
        let footer = OCRProgressText.footer(
            status: .working(elapsedSeconds: 5, step: nil),
            estimate: nil, formattedEstimate: nil)

        XCTAssertFalse(footer.isStalled)
        XCTAssertFalse(footer.text.isEmpty)
    }
}
