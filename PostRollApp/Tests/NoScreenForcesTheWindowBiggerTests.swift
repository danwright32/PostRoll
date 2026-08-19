import XCTest
import SwiftUI
import AppKit

/// No screen may demand a window bigger than a display (#710).
///
/// #687 and #708 are the same defect on two axes: a screen's content dictating
/// the window's size rather than the window constraining the content. Both were
/// found by Dan noticing the window behaving oddly, and #687's own reproduction
/// could not be built from the screen that was showing at the time, so nothing
/// would have caught a third instance on a fourth screen before it shipped.
///
/// This is that check. It hosts every stage screen in turn and asks SwiftUI the
/// same question the window asks: how small are you willing to be? A screen
/// that answers with more than a display can hold is one that can strand the
/// window, and it fails the build here rather than being rediscovered by hand
/// (L30).
///
/// The floor the app sets is deliberately NOT what is asserted. It is known to
/// be overwritten by the content's demand, measured at 353 by 2834 where the
/// code asked for 760 by 500, so a check reading the code's own value would
/// pass while the thing it stands for was being ignored (L188).
@MainActor
final class NoScreenForcesTheWindowBiggerTests: XCTestCase {

    /// The usable height of the display #687 was measured on, and a width to
    /// match. Anything demanding more than this cannot be made to fit.
    private let usable = CGSize(width: 1728, height: 984)

    /// Deliberately generous. What is being caught is a screen demanding
    /// thousands of points, not one that wants a few more than another (L36).
    private var ceiling: CGSize { usable }

    private lazy var root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WindowSizeSweep-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The measurement

    /// What SwiftUI would hand the window as this content's minimum size.
    ///
    /// `.minSize` is the sizing option that propagates a layout's minimum out
    /// to the window, and the constraints it installs are the numbers AppKit
    /// then refuses to go under. The same quantity a probe printed from the
    /// running app while #687 was being found.
    private func demandedMinimum(of view: some View, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = [.minSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        holder.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            host.topAnchor.constraint(equalTo: holder.topAnchor),
        ])
        holder.layoutSubtreeIfNeeded()
        // A second pass: anything with a split view or a lazy stack in it fills
        // in asynchronously, and one pass measures an empty column.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        holder.layoutSubtreeIfNeeded()

        var demanded = CGSize.zero
        for constraint in host.constraints where constraint.relation == .greaterThanOrEqual {
            if constraint.firstAttribute == .width { demanded.width = constraint.constant }
            if constraint.firstAttribute == .height { demanded.height = constraint.constant }
        }
        return demanded
    }

    // MARK: - The fixture

    /// An event carrying far more than a screen can show, because a minimal one
    /// only ever exercises the small branch and this defect lives in the large
    /// one (L101).
    private func crowdedEvent(stage: EventStage) -> Event {
        var event = Event(name: "A Very Long Event Name For Testing Purposes",
                          org: "A Presenting Organisation With A Long Name",
                          venue: "A Concert Hall With A Long Name",
                          date: Date(), shootType: .fullShow)
        event.stage = stage
        event.eventURL = "https://example.com/a/rather/long/event/page/address"
        event.ocrResult = OCRResult(
            performers: (0..<40).map {
                Performer(name: "Performer Number \($0) With A Long Name",
                          role: "principal", voiceOrInstrument: "violin",
                          handle: "@performer\($0)")
            },
            pieces: (0..<30).map {
                Piece(composer: "A Composer With A Long Name \($0)",
                      title: "A Work With A Rather Long Title, Number \($0)",
                      movements: ["Allegro", "Adagio", "Presto"],
                      notes: String(repeating: "A sentence of programme notes. ", count: 4))
            })
        var days: [String: PostingDay] = [:]
        for day in DayName.allCases {
            var posting = PostingDay(day: day)
            posting.photoPaths = (0..<40).map {
                URL(fileURLWithPath: "/tmp/postroll-sweep-\(day.rawValue)-\($0).jpg")
            }
            days[day.rawValue] = posting
        }
        event.days = days
        return event
    }

    private func state(_ event: Event) -> AppState {
        let state = AppState(events: [event],
                             storeURL: root.appendingPathComponent("events.json"),
                             dataRoot: root)
        state.selectedEventID = event.id
        // A banner showing, because the one screen that turned out to be able
        // to do this was the banner strip, and a sweep run without one would
        // have missed #687 entirely.
        state.apply(.known(commit: "1a2b3c4", branch: "wip/sweep", dirty: true))
        return state
    }

    private func hosted(_ event: Event, _ screen: some View) -> some View {
        let state = state(event)
        // Through the same list the app uses, never a copy of it. This test
        // spelled the owners out itself, and adding one to the app then left
        // every screen here crashing on a missing environment value, which is
        // not a failing assertion but a trap (#718, L41).
        return screen
            .environment(state)
            .environment(HashtagStore())
            .environment(AnalyticsStore())
            .withAppOwners(AppOwners())
    }

    // MARK: - The sweep

    func testNoStageScreenDemandsMoreThanADisplayCanHold() {
        // Every stage, at the narrowest width the window allows, because the
        // minimum HEIGHT is computed at the minimum WIDTH and that is exactly
        // where #687's banner wrapped into dozens of lines.
        for stage in EventStage.allCases {
            let event = crowdedEvent(stage: stage)
            let demanded = demandedMinimum(
                of: hosted(event, EventDetailView(event: event)),
                width: WindowFit.floor.width)

            XCTAssertLessThanOrEqual(
                demanded.height, ceiling.height,
                "the \(stage.rawValue) screen demands \(Int(demanded.height))pt of "
                + "minimum height, more than a display holds, so the window it "
                + "is shown in cannot be made to fit")
            XCTAssertLessThanOrEqual(
                demanded.width, ceiling.width,
                "the \(stage.rawValue) screen demands \(Int(demanded.width))pt of "
                + "minimum width, more than a display holds")
        }
    }

    func testTheWholeWindowDoesNotDemandMoreThanADisplayCanHold() {
        // The window as it is really assembled, banners and all, which is where
        // #687 actually lived: not in any stage screen but in the strip below
        // them.
        let event = crowdedEvent(stage: .photosAssigned)
        let demanded = demandedMinimum(of: hosted(event, MainWindowView()),
                                       width: WindowFit.floor.width)

        XCTAssertLessThanOrEqual(demanded.height, ceiling.height,
                                 "the window demands \(Int(demanded.height))pt of "
                                 + "minimum height with everything on screen")
    }

    // MARK: - The control

    func testTheSweepCanActuallyFail() {
        // Without this, a sweep that measured nothing at all would report every
        // screen as fine, and a harness that cannot fail is not a check (L1,
        // L98). This is the exact shape #687 turned out to be: text that
        // refuses to be clipped, asked how tall it must be at a narrow width.
        let offender = Text(String(repeating: "A long sentence about something. ", count: 30))
            .fixedSize(horizontal: false, vertical: true)

        let demanded = demandedMinimum(of: offender, width: WindowFit.floor.width)

        XCTAssertGreaterThan(demanded.height, ceiling.height,
                             "the measurement no longer notices content that "
                             + "demands an impossible height, so the sweep above "
                             + "is passing for a reason that has moved")
    }
}
