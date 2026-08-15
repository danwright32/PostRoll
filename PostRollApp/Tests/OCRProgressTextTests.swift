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

    // MARK: - The guess shown until the run reports (#607)

    /// The elapsed-derived guess advances as the read goes on.
    ///
    /// It lives here rather than inside the view so that the render check in
    /// `HostedControlLegibilityTests` draws the string the app draws, instead
    /// of one typed into a test (L48).
    func testTheGuessAdvancesWithTheClock() {
        XCTAssertEqual(OCRProgressText.elapsedPhase(elapsedSeconds: 0, estimate: nil),
                       "Converting program pages…")
        XCTAssertEqual(OCRProgressText.elapsedPhase(elapsedSeconds: 12, estimate: nil),
                       "Reading the program…")
        XCTAssertEqual(OCRProgressText.elapsedPhase(elapsedSeconds: 500, estimate: nil),
                       "Almost there…")
    }

    /// The thresholds scale to how long this Mac's reads actually take, so the
    /// labels track reality rather than a guess made once.
    func testTheGuessStretchesToFitALongEstimate() {
        XCTAssertEqual(OCRProgressText.elapsedPhase(elapsedSeconds: 12, estimate: 400),
                       "Converting program pages…",
                       "twelve seconds into a read that usually takes four hundred is "
                       + "still the first phase")
        XCTAssertEqual(OCRProgressText.elapsedPhase(elapsedSeconds: 120, estimate: 400),
                       "Reading the program…")
    }

    // MARK: - The elapsed timer

    /// Formatted by the app rather than by whoever reads it, for the same
    /// reason the phases moved here.
    func testTheElapsedTimerReadsAsMinutesAndSeconds() {
        XCTAssertEqual(OCRProgressText.elapsed(seconds: 0), "0:00")
        XCTAssertEqual(OCRProgressText.elapsed(seconds: 7), "0:07")
        XCTAssertEqual(OCRProgressText.elapsed(seconds: 67), "1:07")
        XCTAssertEqual(OCRProgressText.elapsed(seconds: 605), "10:05")
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
