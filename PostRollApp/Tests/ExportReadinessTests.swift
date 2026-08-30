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
        XCTAssertTrue(ExportReadiness.canExport(for: settled(), preset: .balanced, regeneratingDays: []))
        XCTAssertNil(ExportReadiness.blockedReason(for: settled(), preset: .balanced, regeneratingDays: []))
    }

    func testARebuildInFlightBlocksExport() {
        XCTAssertFalse(ExportReadiness.canExport(for: settled(), preset: .balanced, regeneratingDays: [.thursday]))
    }

    func testTheReasonNamesTheDay() {
        // "Not available" with no reason reads as broken. It has to say what
        // it is waiting for.
        let reason = ExportReadiness.blockedReason(for: settled(), preset: .balanced, regeneratingDays: [.thursday])
        XCTAssertEqual(reason, "Waiting for the Thursday rebuild")
    }

    func testTwoDaysReadAsAPair() {
        let reason = ExportReadiness.blockedReason(for: settled(), preset: .balanced, regeneratingDays: [.wednesday, .thursday])
        XCTAssertEqual(reason, "Waiting for the Wednesday and Thursday rebuilds")
    }

    func testThreeOrMoreDaysAreListed() {
        let reason = ExportReadiness.blockedReason(
            for: settled(), preset: .balanced,
            regeneratingDays: [.sunday, .wednesday, .thursday])
        XCTAssertEqual(reason, "Waiting for the Sunday, Wednesday and Thursday rebuilds")
    }

    func testTheDaysAreNamedInWeekOrderNotSetOrder() {
        // A Set has no order, so without sorting the message would reshuffle
        // between renders and read as flicker.
        let a = ExportReadiness.blockedReason(for: settled(), preset: .balanced,
                                              regeneratingDays: [.thursday, .sunday])
        let b = ExportReadiness.blockedReason(for: settled(), preset: .balanced,
                                              regeneratingDays: [.sunday, .thursday])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "Waiting for the Sunday and Thursday rebuilds")
    }

    func testEveryDayCanBlockOnItsOwn() {
        // Thursday's reel is the reported case, but Wednesday's collage takes
        // minutes too, and any of them would export stale.
        for day in DayName.allCases {
            XCTAssertFalse(ExportReadiness.canExport(for: settled(), preset: .balanced,
                                                     regeneratingDays: [day]),
                           "\(day.displayName) must block export while rebuilding")
        }
    }

    // MARK: - A day left half switched (#1010)

    /// A posting layout switch redraws only the days it changes. When one of
    /// those redraws fails, the event says Opening while that day's images are
    /// still the four photo Balanced collage, and the export would ship them
    /// with nothing anywhere saying so.
    func testADayDrawnForThePreviousLayoutBlocksTheExport() {
        var event = settled()
        event.postingPresetOverride = .opening
        event.days["sunday"] = day(.sunday, photos: 7, renderedAs: .balanced)

        let reason = ExportReadiness.blockedReason(for: event, preset: .opening,
                                                   regeneratingDays: [])
        XCTAssertEqual(reason, "Redraw Sunday",
                       "the export has to say WHICH day is still drawn for the "
                       + "layout that was left, or the refusal reads as broken")
        XCTAssertFalse(ExportReadiness.canExport(for: event, preset: .opening,
                                                 regeneratingDays: []))
    }

    /// A day the switch never moved is not stale.
    ///
    /// Sunday with three photos posts three under every layout that governs it,
    /// because the renderer takes `photos[:count]`. Blocking on the recorded
    /// name rather than on what actually changed would refuse an export that is
    /// perfectly correct, and a refusal that fires when nothing is wrong is the
    /// one people learn to work around (L36).
    func testADayTheSwitchDidNotActuallyChangeDoesNotBlock() {
        var event = settled()
        event.postingPresetOverride = .opening
        event.days["sunday"] = day(.sunday, photos: 3, renderedAs: .balanced)
        event.days["tuesday"] = day(.tuesday, photos: 2, renderedAs: .balanced)

        XCTAssertNil(ExportReadiness.blockedReason(for: event, preset: .opening,
                                                   regeneratingDays: []),
                     "neither day changes: Sunday posts its three photos under "
                     + "both layouts, and no preset governs Tuesday at all")
    }

    /// A day with no recorded layout is not accused.
    ///
    /// Every event saved before this was recorded has nil on every day, which
    /// is exactly the backlog a marker based check cannot see (L223). Reading
    /// the absence as a mismatch would block every export in the library at
    /// once; reading it as "no evidence" is the only honest answer.
    func testADayWithNoRecordedLayoutIsNotAccused() {
        var event = settled()
        event.postingPresetOverride = .opening
        event.days["sunday"] = day(.sunday, photos: 7, renderedAs: nil)

        XCTAssertNil(ExportReadiness.blockedReason(for: event, preset: .opening,
                                                   regeneratingDays: []))
    }

    /// Both reasons at once name the rebuild, because it is the one that will
    /// resolve itself: waiting is temporary, a stale day needs Dan to act.
    func testARebuildInFlightIsReportedAheadOfAStaleDay() {
        var event = settled()
        event.postingPresetOverride = .opening
        event.days["sunday"] = day(.sunday, photos: 7, renderedAs: .balanced)

        XCTAssertEqual(ExportReadiness.blockedReason(for: event, preset: .opening,
                                                     regeneratingDays: [.monday]),
                       "Waiting for the Monday rebuild")
    }

    /// An event with nothing assigned and nothing rendered.
    private func settled() -> Event {
        Event(name: "Show", org: "Org", venue: "Hall",
              date: Date(timeIntervalSince1970: 1_700_000_000), shootType: .fullShow)
    }

    private func day(_ name: DayName, photos: Int, renderedAs: PostingPreset?) -> PostingDay {
        var posting = PostingDay(day: name)
        posting.photoPaths = (1...max(photos, 1)).prefix(photos)
            .map { URL(fileURLWithPath: "/photos/\(name.rawValue)-\($0).jpg") }
        posting.renderedPostingPreset = renderedAs
        return posting
    }
}
