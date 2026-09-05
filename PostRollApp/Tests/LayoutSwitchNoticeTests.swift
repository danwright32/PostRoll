import XCTest

/// #1046: one notice for a whole layout switch.
///
/// A day rebuilt from the review screen says so when it lands. A posting layout
/// switch that only needs the images redrawn said nothing at all, deliberately:
/// announcing per day would report three finished rebuilds for one thing Dan
/// did. So the quiet case stayed quiet for a run that takes minutes, and a
/// finished switch and one still going looked the same unless he watched the
/// screen (#95).
final class LayoutSwitchNoticeTests: XCTestCase {

    func testEveryDayLandingIsOneNoticeNamingThem() {
        let notice = LayoutSwitchNotice.of(landed: [.sunday, .monday, .wednesday],
                                           failed: [])

        XCTAssertEqual(notice?.what, "Sunday, Monday, and Wednesday redrawn")
        XCTAssertEqual(notice?.isFailure, false)
    }

    func testOneDayIsNotSaidInThePlural() {
        XCTAssertEqual(LayoutSwitchNotice.of(landed: [.wednesday], failed: [])?.what,
                       "Wednesday redrawn")
    }

    /// A partial switch announced as finished is a success claim over work that
    /// did not happen, and the days that failed are the ones Dan has to do
    /// something about (L12, L80).
    func testAPartialSwitchNamesWhatDidNotLand() {
        let notice = LayoutSwitchNotice.of(landed: [.sunday], failed: [.wednesday])

        XCTAssertEqual(notice?.what,
                       "Sunday redrawn, and Wednesday could not be")
        XCTAssertEqual(notice?.isFailure, true)
    }

    /// The whole run dying is not silence either. Every day failed is still an
    /// answer, and the person is left waiting on a switch that has stopped
    /// (L110).
    func testASwitchWhereNothingLandedSaysSo() {
        let notice = LayoutSwitchNotice.of(landed: [], failed: [.sunday, .monday])

        XCTAssertEqual(notice?.what, "Sunday and Monday could not be redrawn")
        XCTAssertEqual(notice?.isFailure, true)
    }

    /// Nothing claimed is nothing to announce. A notice here would be about a
    /// switch that touched no day at all, which is what the caller's own guard
    /// already refuses (L98).
    func testASwitchThatTouchedNoDaySaysNothing() {
        XCTAssertNil(LayoutSwitchNotice.of(landed: [], failed: []))
    }

    /// Named in the week's own order rather than the order the renderer
    /// happened to finish them in, so two switches over the same days read the
    /// same way (L343).
    func testTheDaysAreNamedInTheWeeksOrder() {
        let notice = LayoutSwitchNotice.of(landed: [.wednesday, .sunday], failed: [])

        XCTAssertEqual(notice?.what, "Sunday and Wednesday redrawn")
    }
}
