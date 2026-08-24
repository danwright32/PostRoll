import AppKit
import XCTest

/// What happens to the app when its window closes (#884, #847).
///
/// Steps 1 and 2 of `docs/HAND-CHECK.md` press this by hand, on the recorded
/// grounds that none of the three ways to close a PostRoll window works under
/// XCUITest: a synthetic Cmd+W, the close button, and the Close menu item
/// (#860). Half of that record has since been contradicted. #877 pressed OK,
/// Escape and Try Again on real alerts on this runner and all three took
/// effect, and #883 typed into the New Event form and pressed Return, so clicks
/// and key presses do reach this app.
///
/// Both remaining halves of #847 are here, in one launch, because they are one
/// sequence: the app has to survive its window closing, and it has to be
/// reachable afterwards. A test that only closes the window proves the app can
/// be made to disappear.
///
/// The reopen is a real reopen, not an activation. Clicking the Dock icon sends
/// the application a reopen event, which is what `PostRollApp` answers by
/// showing a window again; `activate()` does not send one, so a test built on
/// it would report a window that never went away as a window that came back.
final class WindowLifecycleUITests: XCTestCase {

    private let root = LaunchedApp.scratchRoot("window-lifecycle")

    override func setUpWithError() throws {
        continueAfterFailure = true
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("events.json"))
    }

    override func tearDown() {
        LaunchedApp.terminateEveryCopy()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Poll the window count, because closing and opening are not instant.
    private func windowCount(_ app: XCUIApplication, reaches target: Int,
                             within seconds: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if app.windows.count == target { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    func testClosingTheWindowLeavesTheAppRunningAndReachable() throws {
        let app = try LaunchedApp.launch(dataRoot: root,
                                         projectRoot: try BrokenWorld.aCheckout(in: root))
        let copy = try LaunchedApp.theRunningCopy()
        let bundle = try XCTUnwrap(copy.bundleURL, "the running PostRoll has no bundle")

        XCTAssertTrue(windowCount(app, reaches: 1),
                      "the app did not start with one window, so nothing below is "
                      + "about closing one. " + AlertOnScreen.describe(app))

        // The close button, not Cmd+W. A synthetic Cmd+W was measured not to
        // take effect on this runner (#860) and nothing since has contradicted
        // that specifically; a click has been measured to work three times over.
        let close = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists, "the window has no close button in the tree. "
                      + AlertOnScreen.describe(app))
        close.click()

        XCTAssertTrue(windowCount(app, reaches: 0),
                      "the window is still there after its close button was "
                      + "clicked, which is what #860 recorded. "
                      + AlertOnScreen.describe(app))

        // #847 itself. The app must OUTLIVE its window: before it was fixed,
        // closing the last window terminated PostRoll, and a generation running
        // behind it went with it.
        //
        // Asked of the operating system rather than of the harness, so the two
        // sides of the check do not come from one lookup (L70).
        usleep(2_000_000)
        XCTAssertFalse(copy.isTerminated,
                       "PostRoll quit when its last window closed, which is the "
                       + "whole of #847")
        XCTAssertEqual(LaunchedApp.runningCopies.count, 1,
                       "there is no longer exactly one PostRoll running, so the "
                       + "reopen below would be about an undecided copy")

        // And it comes back. Opening a bundle that is already running is what
        // clicking the Dock icon does: it sends a reopen, which is the event
        // the app answers by showing a window again.
        let reopened = expectation(description: "the app was asked to reopen")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            XCTAssertNil(error, "the reopen failed: \(String(describing: error))")
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 30)

        XCTAssertTrue(windowCount(app, reaches: 1),
                      "the window did not come back when the app was reopened, so "
                      + "PostRoll is running with no way to reach it, which is "
                      + "worse than having quit. " + AlertOnScreen.describe(app))
        XCTAssertEqual(LaunchedApp.runningCopies.count, 1,
                       "the reopen started a SECOND copy rather than waking this "
                       + "one, and the second is pointed at the real library")

        // ── the other half of #847, which nothing guards ──────────────────────
        //
        // A command that is dead while the window is closed is the half of #847
        // that no unit test can see: the menu item exists either way, and
        // whether it DOES anything depends on the scene the app declares. Close
        // the window again and ask the menu for a new event.
        close.click()
        XCTAssertTrue(windowCount(app, reaches: 0),
                      "the window did not close a second time. "
                      + AlertOnScreen.describe(app))

        let newEvent = app.menuBars.menuItems["New Event…"]
        XCTAssertTrue(newEvent.waitForExistence(timeout: 20),
                      "there is no New Event command in the menu bar at all. "
                      + AlertOnScreen.describe(app))
        XCTAssertTrue(newEvent.isEnabled,
                      "the New Event command is greyed out with no window open, "
                      + "which is the half of #847 nothing else guards")
        newEvent.click()

        XCTAssertTrue(windowCount(app, reaches: 1),
                      "the New Event command opened no window. "
                      + AlertOnScreen.describe(app))
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 20),
                      "a window came back with no form on it, so the command "
                      + "opened a window and then did nothing. "
                      + AlertOnScreen.describe(app))
    }
}
