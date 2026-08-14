import XCTest

/// #490 and #469: figures that were stored and never shown, shown without emoji.
///
/// `follows` and `durationSec` were persisted on every Meta import and read by
/// nothing. A field that is only ever written looks alive to any is-this-used
/// check, because the write path really does run, so the purpose it was added
/// for silently never happens (L46).
///
/// The row they join drew its figures with emoji, which this app's own copy
/// rules forbid: they render at whatever size and weight the font decides, and
/// VoiceOver announces them by their unicode names.
final class InsightsPostMetricsTests: XCTestCase {

    private func metrics(likes: Int? = nil, comments: Int? = nil, saves: Int? = nil,
                         replies: Int? = nil, reach: Int? = nil, follows: Int? = nil,
                         durationSec: Double? = nil) -> [InsightsDisplay.Metric] {
        InsightsDisplay.metrics(likes: likes, comments: comments, saves: saves,
                                replies: replies, reach: reach, follows: follows,
                                durationSec: durationSec)
    }

    func testAPostWithNoFiguresShowsNone() {
        XCTAssertTrue(metrics().isEmpty)
    }

    func testTheFiguresTheExportCarriedAreShown() {
        let names = metrics(likes: 412, comments: 9, reach: 3_100).map(\.name)

        XCTAssertEqual(names, ["likes", "comments", "reach"])
    }

    /// The two that were stored and never read.
    func testNewFollowersAreShown() {
        let shown = metrics(follows: 7)

        XCTAssertEqual(shown.map(\.value), ["7"])
        XCTAssertEqual(shown.map(\.name), ["new followers"])
    }

    func testAReelsLengthIsShown() {
        XCTAssertEqual(metrics(durationSec: 22.4).map(\.value), ["22s"])
    }

    func testALongReelReadsAsMinutesRatherThanSeconds() {
        XCTAssertEqual(InsightsDisplay.formattedDuration(95), "1m 35s")
    }

    /// Zero new followers is not a figure worth a slot: every ordinary post has
    /// it, and a row of zeroes is what stops the real numbers being read.
    func testZeroFollowsIsNotShown() {
        XCTAssertTrue(metrics(follows: 0).isEmpty)
    }

    func testAPhotoPostShowsNoLength() {
        XCTAssertTrue(metrics(durationSec: 0).isEmpty)
    }

    /// A row of glyphs and numbers is announced as noise, so the whole row goes
    /// out as one sentence.
    func testTheRowReadsAsASentence() {
        XCTAssertEqual(
            InsightsDisplay.metricsLabel(metrics(likes: 412, follows: 7)),
            "likes 412, new followers 7")
    }

    func testEveryFigureUsesASymbolRatherThanAnEmoji() {
        let all = metrics(likes: 1, comments: 1, saves: 1, replies: 1, reach: 1,
                          follows: 1, durationSec: 30)

        XCTAssertEqual(all.count, 7)
        for metric in all {
            XCTAssertFalse(metric.symbol.unicodeScalars.contains { $0.properties.isEmoji },
                           "\(metric.name) is drawn with an emoji: \(metric.symbol)")
            XCTAssertFalse(metric.symbol.isEmpty, "\(metric.name) has no icon at all")
        }
    }

    // MARK: - Which weeks a saved report covers (#490)

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    func testAReportSaysTheWindowItCovers() {
        let range = InsightsDisplay.reportRange(from: date("2026-08-01T00:00:00Z"),
                                                to: date("2026-08-31T00:00:00Z"),
                                                calendar: .current,
                                                formatter: {
                                                    let f = DateFormatter()
                                                    f.dateFormat = "d MMM"
                                                    f.timeZone = TimeZone(identifier: "UTC")
                                                    return f
                                                }())

        XCTAssertEqual(range, "1 Aug to 31 Aug")
    }

    /// A single day's import is one date, not the same date twice.
    func testASingleDayReadsAsOneDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let range = InsightsDisplay.reportRange(from: date("2026-08-01T01:00:00Z"),
                                                to: date("2026-08-01T23:00:00Z"),
                                                calendar: calendar, formatter: formatter)

        XCTAssertEqual(range, "1 Aug")
    }
}
