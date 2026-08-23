import AppKit
import XCTest

/// Closing the window does not quit PostRoll (#847).
///
/// Measured on the real app on 2026-08-23, before this rule existed: Cmd+W
/// terminated the process outright. The frontmost process was proved to be the
/// build under test by resolving its PID from its executable path and checking
/// there was exactly one candidate, the keystroke was sent, and the process was
/// gone.
///
/// That is worse than #847 expected. It asked whether a closed window could be
/// got back, and the answer was that there is nothing to get back to.
///
/// Two reasons it matters, and the second is the serious one.
///
/// Cmd+W means "close this window" in every Mac app, so quitting on it is a
/// surprise, and PostRoll replaces the New Window command, which leaves no
/// obvious way back.
///
/// And the app already knows that quitting while work is in flight is
/// destructive: `BuildBehindSheet` asks all three background managers
/// `hasWorkInFlight` and refuses to start an update while any of them is busy,
/// precisely because installing quits the app (#686). Cmd+W performed that same
/// quit with no such check, so a generation, an export or a page read could be
/// killed by a reflex keystroke.
final class WindowClosingTests: XCTestCase {

    @MainActor
    func testClosingTheLastWindowDoesNotTerminateTheApp() {
        // The delegate answers for the whole application, so this is the rule
        // itself rather than a proxy for it. The UI test in PostRollUITests
        // presses the key; this one is what goes red in the fast suite.
        let delegate = DeepLinkDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
            "closing the PostRoll window quits the app, so Cmd+W kills any "
            + "generation, export or page read in flight with no warning, which "
            + "is the very thing the update sheet refuses to do (#686)")
    }
}
