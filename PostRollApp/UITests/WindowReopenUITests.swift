import AppKit
import XCTest

/// Can the PostRoll window be got back after it is closed? (#847)
///
/// #842 changed PostRoll from a `WindowGroup`, which SwiftUI may open many
/// windows from, to a single `Window` scene. That was the right fix for links
/// leaving a window behind every time, and the link behaviour was measured on
/// the installed build both warm and cold.
///
/// What was never measured is what happens when the window is CLOSED. Under a
/// `WindowGroup`, closing the last window and clicking the Dock icon reopens
/// one. Under a `Window` scene it should be reachable again from the Dock or the
/// Window menu, and "should" was the whole problem: nothing had seen it. If it
/// is not reachable, closing the window leaves PostRoll running with nothing on
/// screen and no way back except quitting and relaunching, and the app replaces
/// the New Window command so there is no obvious escape hatch.
final class WindowReopenUITests: XCTestCase {

    private lazy var dataRoot = LaunchedApp.scratchRoot("reopen")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Left running, a copy from one test is a second copy for the next, and
        // every check about which one is under test then has two answers (L70).
        LaunchedApp.terminateEveryCopy()
        try? FileManager.default.removeItem(at: dataRoot)
    }

    /// Wait for the window count to reach `expected`, or fail saying what it was.
    ///
    /// Polled rather than read once: closing and reopening a window is not
    /// synchronous with the keystroke that asked for it, and a single read taken
    /// too early reports the previous state as the answer.
    /// 30s by default, not 10.
    ///
    /// Every launch here is cold, because teardown ends the app so the next test
    /// cannot inherit a windowless one, and a cold launch on this machine was
    /// measured at over 40 seconds against about two for a warm one. Reopening a
    /// closed window sits on the same curve. A limit set from the warm case
    /// fails on the cold one and reads as the window never coming back (L224).
    private func waitForWindows(_ expected: Int,
                                in app: XCUIApplication,
                                within seconds: TimeInterval = 30,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        var seen = app.windows.count
        while Date() < deadline, seen != expected {
            usleep(200_000)
            seen = app.windows.count
        }
        XCTAssertEqual(seen, expected,
                       "waited \(Int(seconds))s for \(expected) window(s) and "
                       + "the app has \(seen)",
                       file: file, line: line)
    }

    // MARK: - Closing it

    func testClosingTheWindowLeavesTheAppRunning() throws {
        // The premise everything below rests on. If closing the window quit the
        // app, "can it be reopened" would be a different question with a
        // different answer, and the reopen test would be measuring a cold
        // launch while reading as a reopen.
        let app = try LaunchedApp.launch(dataRoot: dataRoot)
        waitForWindows(1, in: app)

        app.typeKey("w", modifierFlags: .command)

        waitForWindows(0, in: app)
        XCTAssertFalse(try LaunchedApp.theRunningCopy().isTerminated,
                       "closing the window quit PostRoll outright")
    }

    // MARK: - Getting it back

    func testTheWindowComesBackWhenTheAppIsReopened() throws {
        // The Dock click, which is what #847 asks about. Opening an application
        // that is already running is exactly the event a Dock click sends, so
        // this is the same question rather than a near neighbour of it.
        let app = try LaunchedApp.launch(dataRoot: dataRoot)
        waitForWindows(1, in: app)
        app.typeKey("w", modifierFlags: .command)
        waitForWindows(0, in: app)

        let running = try LaunchedApp.theRunningCopy()
        let bundle = try XCTUnwrap(running.bundleURL, "the running copy has no bundle")
        let opened = expectation(description: "PostRoll reopened")
        NSWorkspace.shared.openApplication(at: bundle,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            opened.fulfill()
        }
        wait(for: [opened], timeout: 30)

        waitForWindows(1, in: app, within: 60)
    }

    func testALinkArrivingWithTheWindowClosedPutsTheWindowBack() throws {
        // The case #847 and #840 make between them, and neither asks alone.
        //
        // Dan closes the window, then clicks a postroll:// link in a task note.
        // Nothing in the app is on screen to receive it. If the window does not
        // come back, the link is one that appears to do nothing, which is the
        // exact defect #840 was written to remove, reappearing through a door
        // nobody had opened yet.
        //
        // The link is delivered to a NAMED bundle rather than through
        // LaunchServices, which would hand it to whichever of the copies on this
        // machine macOS happens to pick. Several PostRoll.app bundles exist here
        // and one of them is the installed app holding real events (L2, #840).
        let app = try LaunchedApp.launch(dataRoot: dataRoot)
        waitForWindows(1, in: app)
        app.typeKey("w", modifierFlags: .command)
        waitForWindows(0, in: app)

        let running = try LaunchedApp.theRunningCopy()
        let bundle = try XCTUnwrap(running.bundleURL, "the running copy has no bundle")
        let link = try XCTUnwrap(
            URL(string: "postroll://new?name=Closed%20Window%20Test&org=Test%20Org"
                + "&venue=Test%20Hall&room=Test%20Room&date=20260901"
                + "&booking=22222222-2222-4222-8222-222222222222"),
            "the link under test is not a URL at all")

        let opened = expectation(description: "link delivered")
        NSWorkspace.shared.open([link], withApplicationAt: bundle,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            opened.fulfill()
        }
        wait(for: [opened], timeout: 30)

        waitForWindows(1, in: app, within: 60)
    }
}
