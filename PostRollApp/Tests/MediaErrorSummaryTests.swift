import XCTest

/// #262: per-day media failures reach the export screen.
///
/// `generate_media.py` reports a failure per day and exits zero, so a run that
/// lost a day is indistinguishable from a clean one at the process level. The
/// export path read none of it, so an export could announce success over a
/// folder quietly missing an asset, while the SAME failure during a preview run
/// was reported. An error surfaced on one path only is an error nobody sees on
/// the path that matters.
final class MediaErrorSummaryTests: XCTestCase {

    // ── which entries are actually failures ───────────────────────────────────

    func testADayThatRenderedIsNotAFailureEvenWithAnErrorEntry() {
        // generate_media files a note under `errors` for a day that rendered
        // perfectly well with an OPTIONAL input missing (a moved B&W photo).
        // Reading that as a failure claims files are missing that are sitting in
        // the folder, and blocks the export from ever being marked done.
        let failures = MediaErrorSummary.failures(
            errors: ["tuesday": "optional B&W photo not found"],
            paths: ["tuesday": ["story": "/p/tuesday/story.png"]])
        XCTAssertTrue(failures.isEmpty)
    }

    func testADayThatProducedNothingIsAFailure() {
        let failures = MediaErrorSummary.failures(
            errors: ["tuesday": "ffmpeg died"], paths: [:])
        XCTAssertEqual(failures["tuesday"], "ffmpeg died")
    }

    func testADayWithAnEmptyAssetDictIsAFailure() {
        let failures = MediaErrorSummary.failures(
            errors: ["friday": "no clips"], paths: ["friday": [:]])
        XCTAssertEqual(failures.count, 1)
    }

    func testARunLevelFailureIsAFailureBecauseNoDayCarriesIt() {
        let failures = MediaErrorSummary.failures(
            errors: ["graphics_run": "process died"],
            paths: ["tuesday": ["story": "/p/s.png"]])
        XCTAssertEqual(failures.count, 1)
    }

    func testACleanRunSaysNothing() {
        XCTAssertNil(MediaErrorSummary.sentence([:]),
                     "an empty banner on every successful export is how a real "
                     + "warning stops being read")
    }

    func testOneFailedDayIsNamed() throws {
        let s = try XCTUnwrap(MediaErrorSummary.sentence(["tuesday": "ffmpeg died"]))
        XCTAssertTrue(s.contains("Tuesday"), s)
        XCTAssertTrue(s.contains("day's graphics"), s)
    }

    func testSeveralFailedDaysAreAllNamed() throws {
        let s = try XCTUnwrap(MediaErrorSummary.sentence([
            "tuesday": "a", "friday": "b", "sunday": "c",
        ]))
        XCTAssertTrue(s.contains("Sunday"), s)
        XCTAssertTrue(s.contains("Tuesday"), s)
        XCTAssertTrue(s.contains("Friday"), s)
        XCTAssertTrue(s.contains("days' graphics"), s)
    }

    func testDaysAreListedInWeekOrderNotDictionaryOrder() throws {
        // A dictionary has no order, so without sorting the same failure reads
        // differently on each run and looks like a different problem.
        let s = try XCTUnwrap(MediaErrorSummary.sentence(["friday": "a", "sunday": "b"]))
        let sunday = try XCTUnwrap(s.range(of: "Sunday"))
        let friday = try XCTUnwrap(s.range(of: "Friday"))
        XCTAssertTrue(sunday.lowerBound < friday.lowerBound, s)
    }

    func testARunLevelFailureIsStillCounted() throws {
        // Python can report a failure under a key that is not a day name.
        // Dropping it would make the sentence claim fewer problems than there
        // are, which is worse than saying nothing.
        let s = try XCTUnwrap(MediaErrorSummary.sentence(["graphics_run": "process died"]))
        XCTAssertTrue(s.contains("graphics_run"), s)
    }

    func testItSaysWhatIsMissingAndWhatToDo() throws {
        // A message that names a problem and offers nowhere to go leaves the
        // person knowing exactly what is wrong and unable to act (L80).
        let s = try XCTUnwrap(MediaErrorSummary.sentence(["tuesday": "x"]))
        XCTAssertTrue(s.contains("missing"), s)
        XCTAssertTrue(s.lowercased().contains("regenerate"), s)
    }

    func testItDoesNotPasteRawToolOutputAtTheUser() throws {
        // The reasons are ffmpeg stderr. They belong in the log, not on a screen
        // whose next action is "look in that day's folder".
        let s = try XCTUnwrap(MediaErrorSummary.sentence([
            "tuesday": "ffmpeg: Invalid data found when processing input (exit 1)",
        ]))
        XCTAssertFalse(s.contains("Invalid data found"), s)
    }
}
