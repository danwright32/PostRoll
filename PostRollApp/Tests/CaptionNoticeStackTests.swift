import XCTest
import SwiftUI
import AppKit

/// The caption screen's notice stack cannot bury the caption editor (#743).
///
/// `CaptionReviewNotices` draws six kinds of row, two of them added this week:
/// the week run's banner, a refusal, a busy-day refusal (#731), one row per
/// failed day rebuild and per failed cover rebuild (#721), the skipped-photo
/// notices and the media warnings. Nothing measured the screen with several of
/// them standing. `BannerLegibilityTests` checks a row is legible and
/// `RefusalRowTests` checks a row reaches the page, both one or two rows at a
/// time, and the window sweep's crowded fixture records no failures and no
/// refusals at all, so the stack it measures is empty.
///
/// Measured here on 2026-08-20, before any cap existed, at the narrowest column
/// the app can be dragged to: the six kinds standing together came to 680pt,
/// and a week where every day's rebuild AND cover failed came to 1885pt, which
/// is nearly two of Dan's screenfuls of warnings before the first caption.
///
/// Deliberately NOT measured through the window sweep, which is where this was
/// tried first. `NoScreenForcesTheWindowBiggerTests` asks what MINIMUM size a
/// screen demands, and this screen scrolls: measured with the stack empty and
/// with eight notices standing, the window demanded the same 700 by 238.5 both
/// times. A ceiling check there could not have failed whatever the stack did,
/// which is a check that reports every state as fine (L98). What bounds the
/// harm is the stack's own height, and that is what these measure.
@MainActor
final class CaptionNoticeStackTests: XCTestCase {

    /// The narrowest a stage screen is ever drawn at: the smallest window the
    /// app allows with the sidebar at its own floor, less the padding the
    /// screen puts around its notices. Derived from the app's own numbers
    /// rather than spelled again here (L41).
    private var narrowest: CGFloat { WindowFit.detailFloorWidth - 2 * Spacing.xl }

    /// The width the same column has on the display #687 was measured on, with
    /// the sidebar at the width it opens at. The wide case matters because a
    /// row that wraps to three lines when narrow takes one when wide, so the
    /// stack is at its shortest here and a cap has to hold at both ends.
    private let widest: CGFloat = 1728 - 265 - 2 * Spacing.xl

    private let days: [String] = DayName.allCases.map(\.rawValue)

    private func label(_ day: String) -> String {
        DayName(rawValue: day)?.displayName ?? day
    }

    /// What AppKit says this content needs at a fixed width. The idiom
    /// `HostedControlLegibilityTests.heightAt` uses, for the same reason: a
    /// layout that wraps gets taller as it narrows, and one that is capped
    /// stops.
    private func heightAt(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        host.layoutSubtreeIfNeeded()
        // A second pass, because the region measures its own content before it
        // knows how tall to be.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: - The fixtures

    /// Every kind of row the screen can show at once, one or two of each.
    private func sixKinds() -> CaptionReviewNotices {
        CaptionReviewNotices(
            regenerateError: "The week stopped early: the usage cap was reached after "
                           + "Wednesday, so Thursday and Friday were not written.",
            refusal: "The Wednesday collage needs at least 2 photos (you picked 1)",
            rebuildRefusal: "Friday is already rebuilding, so nothing was changed",
            skippedPhotoNotices: [
                CaptionReviewDayNotice(id: "monday",
                                       message: "Monday: one photo was left out because "
                                              + "the file would not open")],
            mediaWarnings: [
                CaptionReviewDayNotice(id: "wednesday",
                                       message: "Wednesday: the optional wide shot had "
                                              + "moved, so the day was built without it")],
            dayRebuildFailures: [
                CaptionReviewDayNotice(id: "tuesday",
                                       message: "Tuesday regeneration failed: clip reel "
                                              + "skipped: ffmpeg crashed writing the reel"),
                CaptionReviewDayNotice(id: "friday",
                                       message: "Friday regeneration failed: "
                                              + "insufficient_clips: only 1 of 1 clips "
                                              + "usable, need at least 3")],
            coverRebuildFailures: [
                CaptionReviewDayNotice(id: "thursday",
                                       message: "Thursday cover regeneration failed: the "
                                              + "chosen frame could not be read")])
    }

    /// A whole week that failed, which is not exotic: one missing ffmpeg fails
    /// every day of a full rebuild, and since #740 a full run records each one.
    private func everyDayFailed() -> CaptionReviewNotices {
        CaptionReviewNotices(
            regenerateError: "The week stopped early: the usage cap was reached after "
                           + "Wednesday, so Thursday and Friday were not written.",
            refusal: "The Wednesday collage needs at least 2 photos (you picked 1)",
            rebuildRefusal: "Friday is already rebuilding, so nothing was changed",
            mediaWarnings: days.map {
                CaptionReviewDayNotice(id: $0, message: "\(label($0)): the optional wide "
                                                      + "shot had moved, so the day was "
                                                      + "built without it") },
            dayRebuildFailures: days.map {
                CaptionReviewDayNotice(id: $0, message: "\(label($0)) regeneration failed: "
                                                      + "ffmpeg is not installed, so no "
                                                      + "reel could be written") },
            coverRebuildFailures: days.map {
                CaptionReviewDayNotice(id: $0, message: "\(label($0)) cover regeneration "
                                                      + "failed: the chosen frame could "
                                                      + "not be read") })
    }

    // MARK: - The defect

    func testAWeekWhereEveryDayFailedDoesNotBuryTheEditor() {
        for width in [narrowest, widest] {
            let height = heightAt(everyDayFailed(), width: width)
            XCTAssertLessThanOrEqual(
                height, CaptionReviewNotices.maximumHeight,
                "at \(Int(width))pt wide a week where every day failed stands "
                + "\(Int(height))pt of notices, which is more than the "
                + "\(Int(CaptionReviewNotices.maximumHeight))pt this screen gives them, "
                + "so the caption editor Dan came here to read starts below it")
        }
    }

    func testTheSixKindsTheScreenCanShowAtOnceFitTheCap() {
        for width in [narrowest, widest] {
            let height = heightAt(sixKinds(), width: width)
            XCTAssertLessThanOrEqual(
                height, CaptionReviewNotices.maximumHeight,
                "the six kinds of notice standing together are \(Int(height))pt tall "
                + "at \(Int(width))pt wide")
        }
    }

    // MARK: - What the cap must not do

    func testASingleNoticeIsNotPaddedOutToTheCap() {
        // The common case by far, and the one a fixed-height region would
        // ruin: one warning must take one warning's worth of screen, not the
        // whole allowance, or every ordinary run gains a gap where nothing is.
        let one = CaptionReviewNotices(
            regenerateError: "The week stopped early: the usage cap was reached after "
                           + "Wednesday, so Thursday and Friday were not written.")
        let height = heightAt(one, width: narrowest)

        XCTAssertGreaterThan(height, 0, "a notice that is on screen draws nothing")
        XCTAssertLessThan(height, CaptionReviewNotices.maximumHeight,
                          "one notice takes the whole \(Int(CaptionReviewNotices.maximumHeight))pt "
                          + "allowance, so an ordinary run leaves an empty band above "
                          + "the captions")
    }

    func testNoNoticesTakeNoRoomAtAll() {
        XCTAssertEqual(heightAt(CaptionReviewNotices(), width: narrowest), 0,
                       "a screen with nothing to say still reserves room for it")
    }

    func testTheCapLeavesMostOfTheSmallestWindowForTheEditor() {
        // The cap is only worth having if what it leaves is usable. Held to the
        // smallest window the app allows rather than to Dan's display, because
        // that is the case where the room runs out first.
        XCTAssertLessThanOrEqual(
            CaptionReviewNotices.maximumHeight, WindowFit.floor.height / 2,
            "the notices may take up to \(Int(CaptionReviewNotices.maximumHeight))pt of a "
            + "\(Int(WindowFit.floor.height))pt window, which leaves less than half of "
            + "the smallest window Dan can drag to for the captions themselves")
    }

    func testTheRowsStillDrawWhenTheStackIsCapped() throws {
        // A cap that clipped everything to nothing would pass every height
        // check above while showing no notice at all, which is the failure the
        // heights cannot see (L146).
        //
        // Hosted through AppKit with ONE layout pass, which is the other thing
        // this proves. The first version of the cap measured the rows into
        // `@State` and framed the region to that, so its height arrived on the
        // pass after the one that drew: this test went red with nothing on the
        // page, and the running app would have shown an empty band where its
        // warnings should be until something else made it lay out again.
        //
        // Not through `ImageRenderer`, which is what the banner harness draws
        // with: measured on 2026-08-20, that renders a `ScrollView` as blank
        // whatever is inside it, so a check written there would fail for a
        // reason that has nothing to do with this screen.
        let canvas = CGSize(width: narrowest, height: CaptionReviewNotices.maximumHeight)
        let empty = try WordFootprint.hosted(
            CaptionReviewNotices().frame(width: canvas.width, height: canvas.height,
                                         alignment: .top)
                .background(PaintedSurfaces.page),
            size: canvas, wordless: false)
        let full = try WordFootprint.hosted(
            everyDayFailed().frame(width: canvas.width, height: canvas.height,
                                   alignment: .top)
                .background(PaintedSurfaces.page),
            size: canvas, wordless: false)

        XCTAssertGreaterThan(
            WordFootprint.share(full, empty), WordFootprint.drawn,
            "with every day failed the notice region draws nothing, so the cap "
            + "has taken the warnings away rather than bounding them")
    }

    // MARK: - The control

    func testTheMeasurementCanStillSeeAStackGrow() {
        // Without this, a measurement that had stopped responding to its input
        // would report every stack as fitting (L1, L98). Two rows below the cap,
        // so what is being proved is the measurement rather than the cap.
        let one = CaptionReviewNotices(
            dayRebuildFailures: [CaptionReviewDayNotice(id: "tuesday",
                                                        message: "Tuesday regeneration failed")])
        let two = CaptionReviewNotices(
            dayRebuildFailures: [
                CaptionReviewDayNotice(id: "tuesday", message: "Tuesday regeneration failed"),
                CaptionReviewDayNotice(id: "friday", message: "Friday regeneration failed")])

        XCTAssertGreaterThan(heightAt(two, width: narrowest),
                             heightAt(one, width: narrowest),
                             "a second notice added no height, so the measurement "
                             + "is not reading the stack it claims to")
    }
}
