import AppKit
import SwiftUI

/// Holding PostRoll's window inside the screen it is on, whatever its content
/// asks for (#690).
///
/// #687 measured the window being given a minimum height of 2834pt against a
/// usable screen height of 984pt, which left it 1850pt below the bottom of the
/// display with no drag able to recover it. AppKit will not size a window below
/// its minimum, so every edge, corner and window command was refused. It was
/// not a window that had drifted off screen, it was a window forbidden from
/// fitting.
///
/// Two independent things were wrong, and this fixes both at the window rather
/// than in whichever view happened to cause it that day. Every screen in this
/// app grows, so the next one is free to do the same:
///
/// * The app sets `window.minSize` and that value was NOT in force. SwiftUI
///   derives a window's size limits from its content, and the content's demand
///   wins, so the line reads as protection while protecting nothing (L188).
/// * Nothing held the window against `NSScreen.visibleFrame`. The only screen
///   aware code was the opening frame, which runs once at window creation and
///   cannot help after any later layout pass.
///
/// The arithmetic is separated from the window on purpose: every rule below can
/// then be stated against a screen rectangle chosen by a test, including the
/// second display and the display too small to hold the floor, neither of which
/// a suite can arrange for real.
enum WindowFit {

    /// The smallest window the app asks for, and after this the smallest one it
    /// actually gets.
    ///
    /// The same pair `WindowConfigurator` has always set. What is new is that
    /// nothing downstream can quietly raise it.
    static let floor = NSSize(width: 760, height: 500)

    /// `frame` made to fit inside `visible`, or `frame` itself when it already
    /// does.
    ///
    /// Returned unchanged in the ordinary case deliberately, so "the guard
    /// fired" is a fact about this window rather than something that happens on
    /// every resize: a backstop that moved every window would be
    /// indistinguishable from one that moved the broken ones (L159), and the
    /// log below depends on the difference.
    static func clamped(_ frame: NSRect, into visible: NSRect,
                        floor: NSSize = WindowFit.floor) -> NSRect {
        // The floor is a floor, not a demand: on a display too small to hold it
        // it would push the window off exactly the way this guard exists to
        // stop, so the screen wins.
        let smallest = NSSize(width: min(floor.width, visible.width),
                              height: min(floor.height, visible.height))
        let size = NSSize(
            width: min(max(frame.width, smallest.width), visible.width),
            height: min(max(frame.height, smallest.height), visible.height))

        // Moved rather than resized wherever moving is enough: a window that
        // was only in the wrong place must come back the same size it was.
        let x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - size.height)

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// What to write to the log when the clamp fired, or nil when it did not.
    ///
    /// A backstop that silently corrects forever hides the layout defect it is
    /// compensating for, so the day a screen starts demanding an impossible
    /// height is discoverable rather than merely absorbed. Nil on an ordinary
    /// resize for the same reason: a line logged every time is a line nobody
    /// reads, and it would drown this one (L11, L36).
    static func report(clamping before: NSRect, to after: NSRect,
                       into visible: NSRect) -> String? {
        guard before != after else { return nil }
        return "[PostRoll] window clamped to the usable screen area: asked for "
             + "\(describe(before)), given \(describe(after)), screen "
             + "\(describe(visible)). Something in the current screen is "
             + "demanding a size the display cannot hold."
    }

    private static func describe(_ rect: NSRect) -> String {
        "\(Int(rect.width))x\(Int(rect.height)) at (\(Int(rect.minX)), \(Int(rect.minY)))"
    }

    private static func describe(_ size: NSSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    /// Take the window's size limits back from its content, and report how many
    /// places were freed.
    ///
    /// This is the half that makes the clamp possible at all. AppKit will not
    /// size a window below `window.minSize`, and SwiftUI derives that pair from
    /// its content's layout and writes it over whatever the app asked for:
    /// #687 measured 353 by 2834 sitting where the app had set 760 by 500. So
    /// the floor is re-asserted here, and it has to be re-asserted rather than
    /// merely set once, because the next layout pass writes it again.
    ///
    /// The hosting views are freed as well as the minimum being restored. The
    /// two are separate routes to the same refusal, and measuring showed only
    /// the second one reproducing here, which is exactly the reason to close
    /// both rather than the one that happened to be observed (L173). The count
    /// returned is the difference between a guard that works and one that runs
    /// and achieves nothing (L98).
    ///
    /// Walked the same way `WindowConfigurator` walks for vibrancy, because the
    /// hosting view is somewhere under the content view rather than being it.
    @MainActor
    @discardableResult
    static func releaseContentSizeLimits(in window: NSWindow) -> Int {
        guard let root = window.contentView else { return 0 }
        var freed = 0
        func walk(_ view: NSView) {
            if let releasable = view as? (any ContentSizeLimiting) {
                releasable.releaseSizeLimits()
                freed += 1
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        // The app's own floor, re-asserted now that nothing else is speaking
        // for it. Set after the release rather than before, because a limit put
        // back while the content still holds a larger one is the situation this
        // whole file is about.
        restoreFloor(in: window)
        return freed
    }

    /// Put the app's floor back, and say what it replaced.
    ///
    /// Returns the minimum that was there when there was one to take back, and
    /// nil when the window was already at the floor. The distinction is the
    /// whole value of this function: it is called on every resize and on the
    /// start of every drag, so a version that could not tell "put it back" from
    /// "nothing to do" would either log on every mouse movement or never say
    /// anything at all, and a backstop that silently corrects forever hides the
    /// defect it is compensating for.
    ///
    /// Cheap on purpose. SwiftUI rewrites the window's minimum whenever it lays
    /// out, so this has to run often rather than once, which is why it is a
    /// comparison and a property write rather than the view tree walk above.
    @MainActor
    @discardableResult
    static func restoreFloor(in window: NSWindow) -> NSSize? {
        guard window.minSize != floor else { return nil }
        let raised = window.minSize
        window.minSize = floor
        return raised
    }

    /// Whether the raised minimum has already been reported this session.
    ///
    /// Once, not every time: the condition recurs on every layout pass, and a
    /// line logged that often is one nobody reads, which would bury the one
    /// that matters (L36).
    @MainActor
    private static var haveReportedRaisedMinimum = false

    /// Bring one window inside `visible`, saying so if it had to.
    ///
    /// `isFullScreen` is passed rather than read here so a test can state the
    /// case. A full screen window is outside `visibleFrame` by design, and
    /// correcting it would drop the app out of full screen on every layout
    /// pass, which is the guard fighting the system rather than the content.
    @MainActor
    static func fit(_ window: NSWindow, into visible: NSRect,
                    isFullScreen: Bool = false) {
        guard !isFullScreen else { return }

        // Unconditional, and before the frame is judged. The window's minimum
        // is what a person's drag obeys, and SwiftUI writes its content's
        // demand over it on every layout pass, so a window that currently FITS
        // can still be one Dan cannot make smaller. Correcting only the frame
        // would leave exactly that (#687, L188).
        if let raised = restoreFloor(in: window), !haveReportedRaisedMinimum {
            haveReportedRaisedMinimum = true
            NSLog("[PostRoll] the window's minimum size had been raised to "
                  + "%@ by its content, above the %@ the app asks for. Put back.",
                  describe(raised), describe(floor))
        }

        let before = window.frame
        let after = clamped(before, into: visible)
        guard let note = report(clamping: before, to: after, into: visible) else {
            return
        }
        // Before the resize, never after: AppKit refuses a frame smaller than
        // the window's minimum, so a clamp that ran while the content still
        // held that minimum would compute the right frame and be ignored. Only
        // on the way through here, so an ordinary resize does not pay for a
        // walk of the whole view tree.
        releaseContentSizeLimits(in: window)
        window.setFrame(after, display: true, animate: false)
        NSLog("%@", note)
    }

    /// The screen a window is on, falling back to the main one.
    ///
    /// `window.screen` is nil while a window is off screen entirely, which is
    /// precisely the state this guard exists to end, so the fallback is not a
    /// nicety: without it the worst case is the one case with no answer (L173).
    @MainActor
    static func visibleFrame(for window: NSWindow) -> NSRect? {
        (window.screen ?? NSScreen.main)?.visibleFrame
    }

    /// Keep one window inside its screen for as long as it exists.
    ///
    /// Resizes, moves and screen changes, because all three can leave a window
    /// outside the usable area and only the first is about the content. The
    /// observations are held by the returned object: a notification centre
    /// outlives what registers with it and holds it unowned (L86), so dropping
    /// this is how the guard silently stops.
    @MainActor
    static func watch(_ window: NSWindow,
                      center: NotificationCenter = .default) -> WindowFitWatch {
        WindowFitWatch(window: window, center: center)
    }
}

/// A hosting view whose size limits can be released without knowing its generic
/// parameter.
///
/// `NSHostingView` is generic over its root view, so a cast has to name the
/// type. SwiftUI's own window content is not `NSHostingView<AnyView>`, and a
/// walk that only matched that would find nothing in the shipping app while
/// passing every test written against a hosting view a test made itself, which
/// is the exact shape of a guard that is green and blind (L96).
@MainActor
protocol ContentSizeLimiting: AnyObject {
    func releaseSizeLimits()
}

extension NSHostingView: ContentSizeLimiting {
    func releaseSizeLimits() { sizingOptions = [] }
}

/// Holds the observations that keep a window inside its screen.
@MainActor
final class WindowFitWatch {
    private var tokens: [NSObjectProtocol] = []
    private let center: NotificationCenter

    init(window: NSWindow, center: NotificationCenter) {
        self.center = center
        // The start of a live resize is in here with the three after the fact
        // ones on purpose, and it is the one that matters for the minimum: a
        // drag is refused by `window.minSize` before any resize notification is
        // ever sent, so a guard that only watched the aftermath would put the
        // floor back too late every time and the drag would go on being
        // refused.
        //
        // `queue: nil` so delivery is synchronous on the thread that posts,
        // which is always the main thread here since AppKit posts these. A main
        // queue observer would be delivered one turn of the run loop later,
        // which for the live resize case is after the drag it exists to allow.
        for name in [NSWindow.willStartLiveResizeNotification,
                     NSWindow.didResizeNotification,
                     NSWindow.didMoveNotification,
                     NSWindow.didChangeScreenNotification] {
            tokens.append(center.addObserver(forName: name, object: window,
                                             queue: nil) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window,
                          let visible = WindowFit.visibleFrame(for: window)
                    else { return }
                    WindowFit.fit(window, into: visible,
                                  isFullScreen: window.styleMask.contains(.fullScreen))
                }
            })
        }
    }

    /// Stop watching.
    ///
    /// A method rather than `deinit`, because a nonisolated deinit cannot touch
    /// the tokens this holds. The window this watches lives as long as the app
    /// does, so nothing has to call this in the shipping app; a test that made
    /// its own window does.
    func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }
}
