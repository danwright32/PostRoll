import XCTest

/// #183: an event's screens can be reached directly, and only when their inputs
/// exist.
///
/// `EventDetailView` routes purely on `event.stage`, so exactly one screen was
/// reachable at a time and moving between them meant walking the back button
/// one screen at a time, each click writing a new stage as a side effect.
/// Editing an asset after reaching export is an ordinary thing to want, and it
/// read as being trapped. #182 is what that looks like when it goes wrong.
///
/// The rules that matter are the refusals: a step bar that lets you open a
/// screen with no inputs is a worse trap than no step bar.
final class StageNavigationTests: XCTestCase {

    private func event(stage: EventStage = .created) -> Event {
        var e = Event(name: "E", org: "O", venue: "V", date: Date(), shootType: .fullShow)
        e.stage = stage
        return e
    }

    private func withProgram() -> Event {
        var e = event()
        e.ocrResult = OCRResult(performers: [], pieces: [], scenes: [])
        return e
    }

    private func withPhotos() -> Event {
        var e = withProgram()
        var day = PostingDay(day: .wednesday)
        day.photoPaths = [URL(fileURLWithPath: "/p/a.jpg")]
        e.days[DayName.wednesday.rawValue] = day
        return e
    }

    private func generated() -> Event {
        var e = withPhotos()
        e.weekResult = WeekGenerationResult()
        return e
    }

    // ── the bar itself ────────────────────────────────────────────────────────

    func testTheBarDoesNotOfferTheOCRRunAsAPlaceToGo() {
        // .programUploaded's screen STARTS the OCR run, so a button for it
        // would silently spend money re-reading a program already read.
        XCTAssertFalse(StageNavigation.steps.contains(.programUploaded))
    }

    func testEveryStageHighlightsSomeStepOnTheBar() {
        // Otherwise two of the seven stages show nothing selected, which reads
        // as being nowhere at all.
        for stage in EventStage.allCases {
            XCTAssertTrue(StageNavigation.steps.contains(StageNavigation.step(containing: stage)),
                          "\(stage) highlights no step")
        }
    }

    func testTheCaptionScreenShowsUnderGenerate() {
        XCTAssertEqual(StageNavigation.step(containing: .captionsReviewed), .assetsGenerated)
    }

    func testTheOCRRunShowsUnderProgram() {
        XCTAssertEqual(StageNavigation.step(containing: .programUploaded), .created)
    }

    // ── what it refuses, and why ──────────────────────────────────────────────

    func testTheProgramScreenIsAlwaysReachable() {
        XCTAssertTrue(StageNavigation.canOpen(.created, in: event()))
    }

    func testReviewingTheProgramNeedsAProgram() throws {
        let reason = try XCTUnwrap(StageNavigation.blockedReason(for: .ocrDone, in: event()))
        XCTAssertTrue(reason.lowercased().contains("program"), reason)
        XCTAssertTrue(StageNavigation.canOpen(.ocrDone, in: withProgram()))
    }

    func testAssigningPhotosNeedsTheProgramToo() {
        XCTAssertNotNil(StageNavigation.blockedReason(for: .photosAssigned, in: event()))
        XCTAssertTrue(StageNavigation.canOpen(.photosAssigned, in: withProgram()))
    }

    func testGeneratingNeedsPhotosOnAtLeastOneDay() throws {
        let reason = try XCTUnwrap(
            StageNavigation.blockedReason(for: .assetsGenerated, in: withProgram()))
        XCTAssertTrue(reason.lowercased().contains("photos"), reason)
        XCTAssertTrue(StageNavigation.canOpen(.assetsGenerated, in: withPhotos()))
    }

    func testADayWithOnlyClipsCountsAsHavingSomethingToGenerate() {
        // Friday's auto-cut reel needs no stills at all, so a clips-only day
        // must not read as an empty week.
        var e = withProgram()
        var friday = PostingDay(day: .friday)
        friday.clipPaths = [URL(fileURLWithPath: "/p/a.mov")]
        e.days[DayName.friday.rawValue] = friday

        XCTAssertTrue(StageNavigation.canOpen(.assetsGenerated, in: e))
    }

    func testExportingNeedsAGeneratedWeek() throws {
        let reason = try XCTUnwrap(StageNavigation.blockedReason(for: .exported, in: withPhotos()))
        XCTAssertTrue(reason.lowercased().contains("generate"), reason)
        XCTAssertTrue(StageNavigation.canOpen(.exported, in: generated()))
    }

    func testAReasonIsGivenRatherThanASilentlyDeadControl() {
        // A control that greys out with no explanation reads as broken, and the
        // reason is the actionable half: it names the work that is missing.
        for stage in StageNavigation.steps {
            if !StageNavigation.canOpen(stage, in: event()) {
                XCTAssertNotNil(StageNavigation.blockedReason(for: stage, in: event()),
                                "\(stage) is blocked with no reason to show")
            }
        }
    }

    // ── going back is always allowed once the work exists ─────────────────────

    func testEveryEarlierScreenIsReachableFromExport() {
        // The complaint in the issue: from the export screen, getting to the
        // Thursday reel was two back clicks and two stage writes.
        var e = generated()
        e.stage = .exported

        for stage in StageNavigation.steps {
            XCTAssertTrue(StageNavigation.canOpen(stage, in: e),
                          "\(stage) is unreachable from the end of the flow")
        }
    }

    func testStepsBehindTheCurrentOneAreMarkedAsDone() {
        XCTAssertTrue(StageNavigation.isBehind(.created, current: .exported))
        XCTAssertTrue(StageNavigation.isBehind(.photosAssigned, current: .exported))
        XCTAssertFalse(StageNavigation.isBehind(.exported, current: .exported))
        XCTAssertFalse(StageNavigation.isBehind(.exported, current: .photosAssigned))
    }

    func testTheCaptionScreenCountsAsBeingAtGenerateNotPastIt() {
        // Otherwise reaching caption review would mark Generate itself done and
        // the bar would claim a milestone the user has not approved.
        XCTAssertFalse(StageNavigation.isBehind(.assetsGenerated, current: .captionsReviewed))
    }
}
