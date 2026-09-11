import XCTest

/// #262: per-day media failures reach the export screen.
/// #265: a failure and a warning are different facts and read differently.
///
/// `generate_media.py` reports per-day trouble and exits zero, so a run that
/// lost a day is indistinguishable from a clean one at the process level. The
/// export path read none of it, so an export could announce success over a
/// folder quietly missing an asset, while the SAME failure during a preview run
/// was reported.
///
/// The first honest reader then over-corrected, because Python filed two
/// different facts under one `errors` key: a day that could not render at all,
/// and a day that rendered fine with an OPTIONAL input missing. That reader
/// claimed a day's graphics were missing while they sat in the folder, and
/// suppressed the Exported milestone and the manifest for a complete export.
/// Python now separates them, so `errors` means failed and nothing else.
final class MediaErrorSummaryTests: XCTestCase {

    // ── failures ──────────────────────────────────────────────────────────────

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

    // #1405: the reason travels with the day.
    //
    // `testItDoesNotPasteRawToolOutputAtTheUser` stood here and asserted the
    // opposite. It was the guard on #262's decision to keep reasons off this
    // screen, whose premise was that a reason is a wall of ffmpeg stderr
    // telling Dan nothing. That premise expired (L316): measured against
    // `tests/fixtures/real_failure_text.json`, the 17 recorded real failures
    // run 22 to 311 characters with a median of 153, and
    // `GenerationFailureText` now turns the recognised ones into a sentence
    // naming what to do. So the test was deleted rather than adjusted, because
    // a test defending a reversed decision becomes the guard on the rejected
    // behaviour (L252). What it protected, that the banner stays readable, is
    // covered by `testTheReasonIsHumanisedWhenItIsRecognised` below, which
    // pins the actionable sentence rather than the raw text, and by
    // `BannerLegibilityTests`, which renders this message on the real screen.
    //
    // The cost of withholding it, measured 2026-09-11: an export failed on a
    // missing reel layout seed, the banner said only that Thursday's graphics
    // could not be generated, and it was answered with a Lightroom re-export
    // of 150 files that changed nothing.

    func testTheFailureCarriesItsReason() throws {
        let s = try XCTUnwrap(MediaErrorSummary.sentence([
            "thursday": "scroll reel failed: build_collage_strip needs a layout seed",
        ]))
        XCTAssertTrue(s.contains("needs a layout seed"),
                      "the cause is the part Dan can act on, and it was already in hand: \(s)")
    }

    func testTheReasonIsHumanisedWhenItIsRecognised() throws {
        // Not the raw text alone. The same failure has to read the same here as
        // it does on the generation screen, which routes through
        // `GenerationFailureText` (L118).
        let s = try XCTUnwrap(MediaErrorSummary.sentence([
            "thursday": "ffmpeg: command not found",
        ]))
        XCTAssertTrue(s.contains("brew install ffmpeg"),
                      "a recognised failure owes Dan the step that fixes it: \(s)")
    }

    func testEachFailedDayCarriesItsOwnReason() throws {
        // One reason standing for two days is how the second one goes unread.
        let s = try XCTUnwrap(MediaErrorSummary.sentence([
            "tuesday": "before and after story failed: the edited photo is not there",
            "thursday": "scroll reel failed: build_collage_strip needs a layout seed",
        ]))
        XCTAssertTrue(s.contains("the edited photo is not there"), s)
        XCTAssertTrue(s.contains("needs a layout seed"), s)
    }

    func testTheReasonDoesNotRunIntoTheSentenceAfterIt() throws {
        // Python's own wording carries no terminator, so the joiner supplies
        // one, and must not supply a second to a reason that already ends in a
        // stop (#405).
        for reason in ["the edited photo is not there",
                       "the edited photo is not there."] {
            let s = try XCTUnwrap(MediaErrorSummary.sentence(["tuesday": reason]))
            XCTAssertFalse(s.contains(".."), "double stop in: \(s)")
            XCTAssertFalse(s.contains(" ."), "orphaned stop in: \(s)")
        }
    }

    // ── warnings ──────────────────────────────────────────────────────────────

    func testNoWarningsSaysNothing() {
        XCTAssertNil(MediaErrorSummary.warningSentence([:]))
    }

    func testAWarningNamesTheDayAndWhatWasMissing() throws {
        // Unlike a failure's reason, a warning's reason is written by our own
        // code and is the actionable part: Dan's next move is to find that file.
        let s = try XCTUnwrap(MediaErrorSummary.warningSentence([
            "tuesday": "B&W photo not found: /photos/bw.jpg",
        ]))
        XCTAssertTrue(s.contains("Tuesday"), s)
        XCTAssertTrue(s.contains("/photos/bw.jpg"), s)
    }

    func testAWarningSaysTheFolderIsStillComplete() throws {
        // The whole point of the split: a warning must not read as a loss.
        let s = try XCTUnwrap(MediaErrorSummary.warningSentence([
            "friday": "B&W photo not found: /photos/bw.jpg",
        ]))
        XCTAssertFalse(s.lowercased().contains("could not be generated"), s)
        XCTAssertTrue(s.lowercased().contains("exported"), s)
    }

    func testAWarningDoesNotNameACauseItCannotKnow() throws {
        // Since #824 this channel also carries a finishing touch that FAILED, in
        // which nothing was missing and an encode did not run. The closing
        // sentence was written for a chosen photo that had moved and asserted
        // that cause on EVERY warning, so it said something untrue about the one
        // case here that is not about a missing file (L11).
        let s = try XCTUnwrap(MediaErrorSummary.warningSentence([
            "friday": "title card skipped, so the reel carries no title: ffmpeg overlay failed",
        ]))
        XCTAssertFalse(s.lowercased().contains("missing input"), s)

        // And it still has to say the folder is complete, which is the whole
        // reason warnings are kept apart from failures. The reason line above it
        // is where the cause is named, by the code that knows it.
        XCTAssertTrue(s.contains("nothing is missing from the folder"), s)
        XCTAssertTrue(s.contains("ffmpeg overlay failed"), s)
    }

    func testWarningDaysAreAlsoListedInWeekOrder() throws {
        let s = try XCTUnwrap(MediaErrorSummary.warningSentence([
            "friday": "a", "tuesday": "b",
        ]))
        let tuesday = try XCTUnwrap(s.range(of: "Tuesday"))
        let friday = try XCTUnwrap(s.range(of: "Friday"))
        XCTAssertTrue(tuesday.lowerBound < friday.lowerBound, s)
    }

    // ── the two are independent ───────────────────────────────────────────────

    func testAWarningOnlyRunHasNoFailureSentence() {
        // The case that cost #262 its first fix: an export whose only complaint
        // is a missing optional photo is a complete export.
        XCTAssertNil(MediaErrorSummary.sentence([:]))
        XCTAssertNotNil(MediaErrorSummary.warningSentence(["tuesday": "B&W photo not found"]))
    }

    func testADayCanFailAndWarnAtOnceWithoutEitherErasingTheOther() throws {
        let failure = try XCTUnwrap(MediaErrorSummary.sentence(["tuesday": "ffmpeg died"]))
        let warning = try XCTUnwrap(MediaErrorSummary.warningSentence([
            "tuesday": "B&W photo not found: /photos/bw.jpg",
        ]))
        XCTAssertTrue(failure.contains("Tuesday"), failure)
        XCTAssertTrue(warning.contains("/photos/bw.jpg"), warning)
    }
}
