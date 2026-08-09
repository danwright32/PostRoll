import XCTest

/// #89: Approve & Export stayed live during a per-day rebuild.
///
/// The failure: apply a change to the Thursday reel, a multi-minute ffmpeg
/// rebuild, then press Approve & Export and pick a folder. The export copies
/// the OLD mp4, because the new one lands in previews after the export
/// finished, so the posting week folder silently holds the version without the
/// edits, discovered after posting.
///
/// The bar already hid the button for caption regeneration, graphics
/// generation and edit review. Per-day rebuilds, the longest running of the
/// four, were the ones it did not consult.
final class ExportReadinessTests: XCTestCase {

    func testNothingRebuildingMeansExportIsAvailable() {
        XCTAssertTrue(ExportReadiness.canExport(regeneratingDays: []))
        XCTAssertNil(ExportReadiness.blockedReason(regeneratingDays: []))
    }

    func testARebuildInFlightBlocksExport() {
        XCTAssertFalse(ExportReadiness.canExport(regeneratingDays: [.thursday]))
    }

    func testTheReasonNamesTheDay() {
        // "Not available" with no reason reads as broken. It has to say what
        // it is waiting for.
        let reason = ExportReadiness.blockedReason(regeneratingDays: [.thursday])
        XCTAssertEqual(reason, "Waiting for the Thursday rebuild")
    }

    func testTwoDaysReadAsAPair() {
        let reason = ExportReadiness.blockedReason(regeneratingDays: [.wednesday, .thursday])
        XCTAssertEqual(reason, "Waiting for the Wednesday and Thursday rebuilds")
    }

    func testThreeOrMoreDaysAreListed() {
        let reason = ExportReadiness.blockedReason(
            regeneratingDays: [.sunday, .wednesday, .thursday])
        XCTAssertEqual(reason, "Waiting for the Sunday, Wednesday and Thursday rebuilds")
    }

    func testTheDaysAreNamedInWeekOrderNotSetOrder() {
        // A Set has no order, so without sorting the message would reshuffle
        // between renders and read as flicker.
        let a = ExportReadiness.blockedReason(regeneratingDays: [.thursday, .sunday])
        let b = ExportReadiness.blockedReason(regeneratingDays: [.sunday, .thursday])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "Waiting for the Sunday and Thursday rebuilds")
    }

    func testEveryDayCanBlockOnItsOwn() {
        // Thursday's reel is the reported case, but Wednesday's collage takes
        // minutes too, and any of them would export stale.
        for day in DayName.allCases {
            XCTAssertFalse(ExportReadiness.canExport(regeneratingDays: [day]),
                           "\(day.displayName) must block export while rebuilding")
        }
    }
}
