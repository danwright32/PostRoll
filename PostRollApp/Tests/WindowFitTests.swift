import XCTest
import SwiftUI
import AppKit

/// The window can never be pushed outside the screen it is on (#690).
///
/// #687 measured PostRoll's window being given a minimum height of 2834pt
/// against a usable screen height of 984pt, which left it 1850pt below the
/// bottom of the display with no drag able to recover it: AppKit will not size
/// a window below its minimum, so every edge, corner and window command was
/// refused. It was not a window that had drifted off screen, it was a window
/// forbidden from fitting.
///
/// Two separate things were wrong and both are guarded here rather than in the
/// view that happened to cause it, because the next screen is free to do the
/// same. Every screen in this app grows: more days, more photos, longer
/// captions, a taller findings panel.
///
/// 1. The app sets `window.minSize` and that value was NOT in force. SwiftUI
///    derives the window's size limits from its content, and the content's
///    demand wins, so a line that reads as protection protects nothing (L188).
/// 2. Nothing anywhere held the window against the screen's `visibleFrame`.
///    The only screen aware code was the opening frame, which runs once at
///    window creation and can never help after a later layout pass.
@MainActor
final class WindowFitTests: XCTestCase {

    /// A screen the size of the one #687 was measured on: 1728 by 1117 with a
    /// menu bar and a Dock, leaving 984pt of usable height starting at 100.
    private let visible = NSRect(x: 0, y: 100, width: 1728, height: 984)

    private func fits(_ frame: NSRect) -> Bool {
        visible.contains(frame)
    }

    // MARK: - The clamp itself

    func testAWindowTallerThanTheScreenIsBroughtInside() {
        // The measured failure, as a frame: 2834 tall, sitting 1850pt below the
        // usable area.
        let broken = NSRect(x: 0, y: -1750, width: 1728, height: 2834)

        let fitted = WindowFit.clamped(broken, into: visible)

        XCTAssertTrue(fits(fitted),
                      "the window is still outside the usable area at \(fitted), "
                      + "which is where no drag can reach it")
        XCTAssertEqual(fitted.height, visible.height)
    }

    func testAWindowThatAlreadyFitsIsLeftExactlyWhereItIs() {
        // The control, and the thing that makes "the guard fired" mean
        // something: a clamp that moved every window would be indistinguishable
        // from one that moved the broken ones (L159).
        let fine = NSRect(x: 40, y: 160, width: 1200, height: 760)
        XCTAssertEqual(WindowFit.clamped(fine, into: visible), fine)
    }

    func testAWindowPushedBelowTheDockIsMovedBackUp() {
        // Small enough to fit, in the wrong place. Size alone would not fix it.
        let low = NSRect(x: 20, y: -400, width: 1000, height: 700)

        let fitted = WindowFit.clamped(low, into: visible)

        XCTAssertTrue(fits(fitted), "\(fitted) is still off the bottom")
        XCTAssertEqual(fitted.size, low.size,
                       "a window that only needed moving was resized as well")
    }

    func testAWindowPushedOffTheRightIsMovedBackIn() {
        let out = NSRect(x: 1700, y: 200, width: 1000, height: 700)
        XCTAssertTrue(fits(WindowFit.clamped(out, into: visible)))
    }

    func testTheAppsOwnFloorIsTheMinimum() {
        // The other half of #690: the minimum the app asks for is the minimum
        // actually in force, rather than one the content can talk it out of.
        let squashed = NSRect(x: 100, y: 200, width: 300, height: 120)

        let fitted = WindowFit.clamped(squashed, into: visible)

        XCTAssertEqual(fitted.width, WindowFit.floor.width)
        XCTAssertEqual(fitted.height, WindowFit.floor.height)
        XCTAssertTrue(fits(fitted))
    }

    func testAScreenSmallerThanTheFloorWinsOverTheFloor() {
        // The floor exists to keep the window usable, not to push it off a
        // small display. Enforcing it on a screen that cannot hold it would
        // recreate the exact defect this guards against, on a laptop.
        let small = NSRect(x: 0, y: 0, width: 640, height: 400)

        let fitted = WindowFit.clamped(NSRect(x: 0, y: 0, width: 1200, height: 900),
                                       into: small)

        XCTAssertTrue(small.contains(fitted), "\(fitted) does not fit \(small)")
        XCTAssertEqual(fitted.size, small.size)
    }

    func testAWindowOnASecondDisplayIsHeldToThatDisplay() {
        // visibleFrame is per screen, and a window dragged to a shorter display
        // must be judged against the one it is on rather than against whichever
        // screen happens to be main.
        let second = NSRect(x: 1728, y: 0, width: 1512, height: 800)
        let dragged = NSRect(x: 1800, y: 0, width: 1400, height: 1000)

        let fitted = WindowFit.clamped(dragged, into: second)

        XCTAssertTrue(second.contains(fitted), "\(fitted) does not fit \(second)")
    }

    // MARK: - Saying so

    func testAClampThatFiredSaysWhatItDid() {
        // A backstop that silently corrects forever hides the layout defect it
        // is compensating for, so the day a screen starts demanding an
        // impossible height is discoverable rather than merely absorbed.
        let broken = NSRect(x: 0, y: -1750, width: 1728, height: 2834)
        let note = WindowFit.report(clamping: broken,
                                    to: WindowFit.clamped(broken, into: visible),
                                    into: visible)

        let message = try? XCTUnwrap(note)
        XCTAssertEqual(message?.contains("2834"), true,
                       "the size that was refused is not in the message, so the "
                       + "log cannot say which screen asked for it: \(note ?? "nothing")")
    }

    func testAClampThatDidNothingSaysNothing() {
        // Distinct causes, distinct messages (L11). A line logged on every
        // ordinary resize is a line nobody reads, and it would drown the one
        // that matters.
        let fine = NSRect(x: 40, y: 160, width: 1200, height: 760)
        XCTAssertNil(WindowFit.report(clamping: fine, to: fine, into: visible))
    }

    // MARK: - Against a real window whose content demands the impossible

    /// Content that reports an impossible minimum height, measured rather than
    /// imagined: `fixedSize(vertical:)` around a tall column republishes the
    /// whole content height as a MINIMUM, which is the shape #687 found (a
    /// plain ScrollView, a ZStack over one and FadingScrollView all correctly
    /// report a minimum of zero).
    private var impossibleContent: some View {
        VStack(spacing: 8) {
            ForEach(0..<60, id: \.self) { index in
                Text("Row \(index)").frame(height: 40)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A window whose SIZE LIMITS come from its content, which is how SwiftUI
    /// hosts a scene and the mechanism #687 measured.
    ///
    /// Both halves are needed and both were measured: `sizingOptions` carrying
    /// `.minSize` is what makes the hosting view publish the layout's minimum,
    /// and auto layout is what turns that into constraints the window obeys.
    /// Without them the window shrinks freely, and the test below would pass
    /// with the guard deleted.
    private func windowHoldingImpossibleContent() -> NSWindow {
        let host = NSHostingView(rootView: AnyView(impossibleContent))
        host.sizingOptions = [.minSize]
        host.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.layoutIfNeeded()
        return window
    }

    /// The window's minimum as #687 measured it: 353 by 2834, written onto the
    /// window itself.
    ///
    /// That is the mechanism, and it is worth being exact about which one it
    /// is. Constraints under the content view do NOT refuse a smaller frame,
    /// measured here first and found not to reproduce it; what refuses is
    /// `window.minSize`, which SwiftUI derives from the content's layout and
    /// writes over whatever the app asked for. So this is the state to
    /// reproduce, and the guard's job is to take that number back.
    private func demandingAnImpossibleMinimum(_ window: NSWindow) {
        window.minSize = NSSize(width: 353, height: 2834)
    }

    /// Which half of the defect this is, because the two halves are refused by
    /// different things and only one of them is a drag.
    ///
    /// `window.minSize` is what a person's resize obeys, and `setFrame` does
    /// not, measured here rather than assumed: with the minimum set to 2834 a
    /// programmatic `setFrame` to 600 is honoured. That is the whole shape of
    /// #687. The window could always have been brought back in code, and no
    /// edge, corner or window command could do it, because every one of those
    /// goes through the minimum.
    ///
    /// So the fix is both halves, and each fails differently without the other:
    /// take the minimum back, or Dan is left with a window he still cannot drag
    /// smaller; clamp the frame, or he is left with one that is legal to drag
    /// but currently 1850pt below the bottom of the screen.
    func testTheWindowsMinimumIsTakenBackFromTheContent() throws {
        let window = windowHoldingImpossibleContent()
        demandingAnImpossibleMinimum(window)

        // The control: the fixture really is in the state this guards against,
        // rather than the assertion below being true of a fresh window (L159).
        XCTAssertGreaterThan(window.minSize.height, visible.height,
                             "the fixture is not demanding an impossible "
                             + "minimum, so there is nothing here to take back")

        let freed = WindowFit.releaseContentSizeLimits(in: window)

        XCTAssertGreaterThan(freed, 0,
                             "no hosting view was found, so half the guard did "
                             + "nothing at all and its silence reads as success")
        XCTAssertEqual(window.minSize, WindowFit.floor,
                       "the window still refuses to be dragged smaller than the "
                       + "content asked for, which is what left it stuck")
    }

    func testAWindowThatFitsCanStillHaveItsMinimumTakenBack() throws {
        // The case a frame check alone misses entirely. SwiftUI writes its
        // content's demand over the window's minimum on every layout pass, so a
        // window sitting perfectly inside the screen can still be one Dan
        // cannot drag any smaller, and nothing about its position says so.
        let window = windowHoldingImpossibleContent()
        window.setFrame(NSRect(x: 40, y: 160, width: 1200, height: 760),
                        display: false)
        demandingAnImpossibleMinimum(window)

        WindowFit.fit(window, into: visible)

        XCTAssertEqual(window.minSize, WindowFit.floor,
                       "the window fits, so nothing corrected its minimum, and "
                       + "it still cannot be dragged smaller")
    }

    func testTakingTheFloorBackSaysWhetherThereWasAnythingToTakeBack() throws {
        // A guard called on every resize and every drag has to be able to tell
        // "put it back" from "nothing to do", or it either says something every
        // time or never says anything at all (L11).
        let window = windowHoldingImpossibleContent()
        window.minSize = WindowFit.floor
        XCTAssertNil(WindowFit.restoreFloor(in: window))

        demandingAnImpossibleMinimum(window)
        XCTAssertEqual(WindowFit.restoreFloor(in: window)?.height, 2834)
    }

    func testADragIsFreedBeforeItStartsRatherThanAfterItEnds() throws {
        // The moment that matters for a person: `window.minSize` refuses a drag
        // before any resize notification is sent, so the floor has to be back
        // by the time the drag begins.
        let window = windowHoldingImpossibleContent()
        let center = NotificationCenter()
        let watch = WindowFit.watch(window, center: center)
        defer { watch.stop() }
        demandingAnImpossibleMinimum(window)

        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)

        XCTAssertEqual(window.minSize, WindowFit.floor,
                       "the drag starts against the content's minimum, so it is "
                       + "refused exactly as it was before this guard existed")
    }

    func testTheWatchStopsWatchingWhenItIsStopped() throws {
        // The control for the test above: it must be the watch doing that, not
        // something else in the fixture (L159).
        let window = windowHoldingImpossibleContent()
        let center = NotificationCenter()
        let watch = WindowFit.watch(window, center: center)
        watch.stop()
        demandingAnImpossibleMinimum(window)

        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)

        XCTAssertEqual(window.minSize.height, 2834,
                       "something other than the watch is restoring the floor, "
                       + "so the previous test proves nothing about it")
    }

    func testAnOversizedWindowIsPulledBackInsideTheScreen() throws {
        // End to end, against the real refusal: the window is both oversized
        // and forbidden from shrinking, which is the state Dan was left in.
        let window = windowHoldingImpossibleContent()
        window.setFrame(NSRect(x: 0, y: -1750, width: 1728, height: 2834),
                        display: false)
        demandingAnImpossibleMinimum(window)

        WindowFit.fit(window, into: visible)

        XCTAssertTrue(fits(window.frame),
                      "a window restored oversized reopens oversized: \(window.frame)")
    }

    func testAFullScreenWindowIsLeftAlone() throws {
        // The clamp must not fight the system. A full screen window is outside
        // visibleFrame by design, and correcting it would drop the app out of
        // full screen on every layout pass.
        let window = windowHoldingImpossibleContent()
        let asked = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        window.setFrame(asked, display: false)
        let before = window.frame

        WindowFit.fit(window, into: visible, isFullScreen: true)

        XCTAssertEqual(window.frame, before,
                       "the clamp resized a full screen window")
    }

    // MARK: - The opening size, when macOS restored a cramped frame (#1335)

    /// The rule lived inline in `MainWindowView` against the live `NSScreen`,
    /// with its four numbers written where nothing could reach them. A rule
    /// somebody decided, computed from a global at the point of use, is a rule
    /// no test can check either way, which is the whole of #1335.
    private var screen: NSRect { NSRect(x: 0, y: 100, width: 1728, height: 984) }

    func testACrampedRestoredFrameIsOpenedOut() {
        let restored = NSRect(x: 40, y: 140, width: 820, height: 600)

        let opened = WindowFit.opening(from: restored, on: screen)

        XCTAssertGreaterThan(opened.width, restored.width,
                             "a window macOS restored too narrow was left that way")
        XCTAssertEqual(opened.width, (screen.width * 0.82).rounded())
        XCTAssertEqual(opened.height, (screen.height * 0.84).rounded())
    }

    func testAFrameThatIsAlreadyRoomyIsLeftExactlyAlone() {
        // The control. Without it the rule above is satisfied by one that
        // resizes every window on every launch, which would throw away a size
        // Dan chose (L159).
        let roomy = NSRect(x: 10, y: 120, width: 1400, height: 800)

        XCTAssertEqual(WindowFit.opening(from: roomy, on: screen), roomy)
    }

    func testTheOpenedWindowIsCentredOnTheVisibleArea() {
        let opened = WindowFit.opening(
            from: NSRect(x: 0, y: 0, width: 500, height: 400), on: screen)

        XCTAssertEqual(opened.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(opened.midY, screen.midY, accuracy: 1)
    }

    func testTheOpenedWindowStaysInsideTheScreenItWasGiven() {
        // On a display smaller than the width the rule wants, the screen wins,
        // the same way `clamped` lets it.
        let small = NSRect(x: 0, y: 0, width: 900, height: 600)

        let opened = WindowFit.opening(
            from: NSRect(x: 0, y: 0, width: 400, height: 300), on: small)

        XCTAssertLessThanOrEqual(opened.maxX, small.maxX)
        XCTAssertLessThanOrEqual(opened.maxY, small.maxY)
        XCTAssertGreaterThanOrEqual(opened.minX, small.minX)
        XCTAssertGreaterThanOrEqual(opened.minY, small.minY)
    }
}

