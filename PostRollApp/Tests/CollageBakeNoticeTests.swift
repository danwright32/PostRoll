import XCTest

/// #447: a failed collage bake was indistinguishable from having no edits to
/// bake, so the export finished clean carrying Python's raw base PNG without
/// Dan's crop offsets and cell edits, and nothing said so.
final class CollageBakeNoticeTests: XCTestCase {

    func testACleanRunSaysNothing() {
        XCTAssertNil(CollageBakeNotice.sentence([]))
    }

    func testTheNoticeNamesTheDayAndWhatIsActuallyInTheFolder() throws {
        let notice = try XCTUnwrap(CollageBakeNotice.sentence(
            [(day: "Wednesday", reason: .layoutDoesNotMatchThePhotos)]))

        XCTAssertTrue(notice.contains("Wednesday"), notice)
        // The consequence, not just the fault: what he is about to upload is
        // the machine's collage rather than the one he adjusted.
        XCTAssertTrue(notice.contains("rather than the one you"), notice)
    }

    func testTheTwoCausesReadDifferently() {
        // Distinct causes get distinct messages (L11). One is a layout that no
        // longer fits the photos, which he can fix by redoing the layout; the
        // other is a render that failed, which he cannot.
        XCTAssertNotEqual(CollageBakeNotice.describe(.layoutDoesNotMatchThePhotos),
                          CollageBakeNotice.describe(.renderFailed))
    }

    func testEveryDayIsNamedRatherThanCounted() throws {
        let notice = try XCTUnwrap(CollageBakeNotice.sentence([
            (day: "Sunday", reason: .renderFailed),
            (day: "Wednesday", reason: .layoutDoesNotMatchThePhotos),
        ]))
        XCTAssertTrue(notice.contains("Sunday"), notice)
        XCTAssertTrue(notice.contains("Wednesday"), notice)
        XCTAssertTrue(notice.contains("2 days"), notice)
    }

    /// The bake is only silent when there was nothing to bake FROM, which the
    /// copy step reports itself. Anything else has to be said out loud.
    func testOnlyNothingToBakeIsAllowedToBeSilent() {
        let silent: [CollageBakeOutcome] = [.nothingToBake]
        let loud: [CollageBakeOutcome] = [
            .couldNotApplyEdits(.layoutDoesNotMatchThePhotos),
            .couldNotApplyEdits(.renderFailed),
        ]
        for outcome in silent {
            XCTAssertEqual(outcome, .nothingToBake)
        }
        for outcome in loud {
            guard case .couldNotApplyEdits(let reason) = outcome else {
                return XCTFail("\(outcome) should carry a reason")
            }
            XCTAssertFalse(CollageBakeNotice.describe(reason).isEmpty)
        }
    }
}
