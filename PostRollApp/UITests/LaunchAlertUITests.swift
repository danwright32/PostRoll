import AppKit
import XCTest

/// What the window actually puts on screen when a launch check fails (#877).
///
/// These were ruled out once. #855 asked for exactly this, a test that raises
/// each alert against the real app and reads the words and the buttons on
/// screen, and it was abandoned because #860 concluded XCUITest goes blind on a
/// PostRoll window: the application reported as `Disabled` with an empty
/// element subtree. Every later decision inherited that, including the note
/// saying the harness cannot read a form or an alert, and steps 5 and 6 of
/// `docs/HAND-CHECK.md` exist because of it.
///
/// That conclusion was measured again on 2026-08-23 and is wrong. The app
/// reports `runningForeground` and the element tree is about 17,800 characters,
/// unchanged across fifteen seconds. Only the window CLOSING fails. Reading
/// works, so the reason these questions were manual has gone, and a decision
/// resting on a premise now known to be false is re-checked rather than
/// inherited (L61).
///
/// Each class here is one launch, because the condition it is about is set
/// before the app starts and cannot be changed afterwards. The cost is real and
/// is the reason there are four of them and not eight: `AppEntryPointUITests`
/// measured a launch at about 42 seconds on the runner.
///
/// The tree is printed on every run, pass or fail. The first dispatch of this
/// file is a measurement as much as a test, and a green run that prints nothing
/// says only that the assertions written by somebody guessing happened to hold.
///
/// ── what the first dispatch measured, run 32672296758 on 2026-08-23 ─────────
///
/// Five of six assertions held on the runner, and the sixth was this file's own
/// defect rather than the app's. The alert is entirely readable:
///
/// ```
/// Sheet, {{382.0, 211.0}, {260.0, 314.0}}, label: 'alert', Keyboard Focused
///   StaticText, identifier: '_NS:74', value: PostRoll cannot ge...
///   StaticText, identifier: '_NS:58', value: PostRoll found /Us...
///   Button, identifier: 'action-button-1', label: 'OK'
/// ```
///
/// Two things worth keeping. The words arrive as a static text's VALUE and its
/// label is empty, which is why `words(in:)` reads both. And the application
/// and window are marked `Disabled` while the sheet is up: that is the exact
/// symptom #860 recorded as the harness going blind, and it is nothing of the
/// sort. It is a window behind a modal, correctly reported, with its whole
/// subtree present at about 17,700 characters.
///
/// The four launches cost 171.8 seconds of the job, at roughly 42 seconds each.
/// That is what these questions cost to ask automatically, against a manual
/// routine that costs twenty minutes and only runs when somebody remembers.

// MARK: - The titles, in one place

/// The alert titles this file expects, spelled once.
///
/// The UI test target compiles `UITests/` only, so it cannot reference
/// `WindowAlertText` and these have to be literals. A copy of a string that
/// lives in Swift somewhere else is a copy that drifts, so
/// `tests/test_ui_tests_quote_the_real_alerts.py` holds this enum to the titles
/// the window can actually produce, in both directions: a renamed alert fails
/// there, and so does a new alert this file says nothing about (L96).
enum AlertTitle {
    static let dataLoad = "Saved events could not be read"
    static let storeUnavailable = "PostRoll cannot open your events"
    static let projectRoot = "PostRoll cannot generate anything"
}

// MARK: - Reading an alert

/// What is on screen, asked of the running app.
enum AlertOnScreen {

    /// The words every static text on screen is carrying.
    ///
    /// From `value` as well as `label`, because an alert's title and message
    /// arrive as static texts whose text is the VALUE and whose label is empty.
    /// A check reading only the label finds nothing while the words are plainly
    /// on the screen, which is the failure this file shipped with on its first
    /// dispatch: run 32672296758 on 2026-08-23, where the tree held
    /// `StaticText, value: PostRoll found /Us...` and the assertion reported
    /// that nothing named the folder.
    static func words(in app: XCUIApplication) -> [String] {
        app.staticTexts.allElementsBoundByIndex.flatMap { element -> [String] in
            [element.label, element.value as? String ?? ""].filter { !$0.isEmpty }
        }
    }

    /// Whether an alert carrying `title` is up, within `seconds`.
    ///
    /// Three element types are polled together rather than waited on in turn:
    /// `waitForExistence` on each would multiply the timeout by three, and a
    /// macOS alert has been seen described as a sheet, as a dialog and as plain
    /// static text depending on how it was raised.
    static func showing(_ title: String, in app: XCUIApplication,
                        within seconds: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if app.staticTexts[title].exists
                || app.sheets[title].exists
                || app.dialogs[title].exists {
                return true
            }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    /// The labels of the buttons on the alert, or on the whole app when no
    /// alert container can be found.
    ///
    /// Which of those two it was is RETURNED rather than hidden, because a
    /// button list read off the whole window and one read off the alert are
    /// different measurements, and a check that cannot tell them apart would
    /// pass on a window that happens to carry a button of the same name.
    static func buttons(in app: XCUIApplication) -> (labels: [String], fromAlert: Bool) {
        for container in [app.sheets.firstMatch, app.dialogs.firstMatch] where container.exists {
            return (labels(of: container.buttons), true)
        }
        return (labels(of: app.buttons), false)
    }

    private static func labels(of buttons: XCUIElementQuery) -> [String] {
        buttons.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }
    }

    /// Press a button on the alert, saying so when it was not there to press.
    ///
    /// Through the sheet rather than the application, so a button of the same
    /// name elsewhere on the window cannot answer for it.
    static func press(_ label: String, in app: XCUIApplication) -> Bool {
        let sheet = app.sheets.firstMatch
        guard sheet.exists else { return false }
        let button = sheet.buttons[label]
        guard button.exists else { return false }
        button.click()
        return true
    }

    /// Whether an alert carrying `title` has GONE, within `seconds`.
    ///
    /// Its own function rather than a negation of `showing`, because the two
    /// wait for opposite things: asking `showing` to be false returns the
    /// instant it is polled, before anything had a chance to tear down, and a
    /// dismissal that has not happened yet is indistinguishable from one that
    /// worked (L106).
    static func gone(_ title: String, in app: XCUIApplication,
                     within seconds: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if !app.staticTexts[title].exists { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    /// Everything the harness can see, for a failure message that is worth
    /// reading. A failure saying only that a title was absent cannot tell an
    /// alert with the wrong words from a harness that saw nothing at all.
    static func describe(_ app: XCUIApplication) -> String {
        let tree = app.debugDescription
        return "state=\(app.state.rawValue) windows=\(app.windows.count) "
            + "treeLength=\(tree.count)\n\(tree)"
    }
}

// MARK: - A launch with a deliberately broken world

/// The states the launch checks report on, built in a scratch data root.
///
/// The same states `PostRollApp/hand-check.sh` builds for the manual routine,
/// and deliberately not built by calling it: this target drives the shipping
/// app through its real surfaces, and shelling out to the checklist's own setup
/// would make a green run here depend on that script as well as on the app.
enum BrokenWorld {

    static func store(_ contents: String, in root: URL, readable: Bool = true) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("events.json")
        try Data(contents.utf8).write(to: file)
        if !readable {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        }
    }

    /// A folder the launch check reads as a working checkout.
    ///
    /// Passed by every test that is NOT about the code folder, and that is not
    /// tidiness. The runner's own checkout has no `venv/bin/python3`: nothing
    /// in `ui.yml` builds one, so an app launched without this raises the code
    /// folder alert as well as the one the test is about, and the two are
    /// queued with only one on screen. The test would then fail for a reason
    /// that has nothing to do with what it asks, on an environment nobody
    /// declared (L2).
    ///
    /// It mirrors what `AppPaths.projectRootProblem` actually looks for, which
    /// is two paths existing, rather than being a real checkout.
    static func aCheckout(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("checkout")
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("postroll"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("venv/bin"),
                               withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8)
            .write(to: folder.appendingPathComponent("venv/bin/python3"))
        return folder
    }

    /// A folder that exists and is not a checkout, which is a different problem
    /// from a folder that is missing and raises a different message.
    static func notACheckout(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("not-a-checkout")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a checkout".utf8)
            .write(to: folder.appendingPathComponent("README.txt"))
        return folder
    }

    /// Put back whatever was made unreadable, then remove it.
    ///
    /// A store left at mode 000 cannot be deleted from a folder that can
    /// otherwise be read, so a teardown that skipped this would leave the
    /// scratch root behind on every run that used one.
    static func remove(_ root: URL) {
        let file = root.appendingPathComponent("events.json")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - A store that was read and turned out to be bad

final class CorruptStoreAlertUITests: XCTestCase {

    private let root = LaunchedApp.scratchRoot("corrupt-store")

    override func setUpWithError() throws {
        // Every assertion in the method is about the same screen, so one that
        // fails must not hide the rest: the whole value of a run here is the
        // full description of what was on the window.
        continueAfterFailure = true
        try BrokenWorld.store("this is not json", in: root)
    }

    override func tearDown() {
        LaunchedApp.terminateEveryCopy()
        BrokenWorld.remove(root)
        super.tearDown()
    }

    func testTheAlertSaysTheEventsCouldNotBeRead() throws {
        let app = try LaunchedApp.launch(dataRoot: root,
                                         projectRoot: try BrokenWorld.aCheckout(in: root))
        print("CorruptStoreAlertUITests:\n\(AlertOnScreen.describe(app))")

        XCTAssertTrue(AlertOnScreen.showing(AlertTitle.dataLoad, in: app),
                      "the alert titled \(AlertTitle.dataLoad) is not on screen. "
                      + AlertOnScreen.describe(app))

        // Named separately, because "the alert I asked about is not showing" and
        // "a different alert is showing instead" send whoever reads the failure
        // to different places, and the second is the one this file has already
        // had to be fixed for once.
        XCTAssertFalse(app.staticTexts[AlertTitle.projectRoot].exists,
                       "the code folder alert is on screen instead, so this "
                       + "launch had two problems and the queue chose the other one")

        let (labels, fromAlert) = AlertOnScreen.buttons(in: app)
        XCTAssertTrue(labels.contains("OK"),
                      "the way out of this alert is not there. Buttons "
                      + "(fromAlert=\(fromAlert)): \(labels)")

        // And it works. A button that is present and does nothing is the same
        // dead end as no button at all, and it is what step 5 of the hand check
        // presses by hand today.
        XCTAssertTrue(AlertOnScreen.press("OK", in: app), "there was no OK to press")
        XCTAssertTrue(AlertOnScreen.gone(AlertTitle.dataLoad, in: app),
                      "OK did not take the alert away. " + AlertOnScreen.describe(app))

        // Gone and staying gone. An alert that comes back on the next tick is
        // one Dan dismisses on reflex, which is how a warning stops being read.
        usleep(2_000_000)
        XCTAssertFalse(app.staticTexts[AlertTitle.dataLoad].exists,
                       "the alert came back after being dismissed. "
                       + AlertOnScreen.describe(app))
    }
}

// MARK: - A store that could not be read at all

final class UnreadableStoreAlertUITests: XCTestCase {

    private let root = LaunchedApp.scratchRoot("unreadable-store")

    override func setUpWithError() throws {
        continueAfterFailure = true
        try BrokenWorld.store("[]", in: root, readable: false)
    }

    override func tearDown() {
        LaunchedApp.terminateEveryCopy()
        BrokenWorld.remove(root)
        super.tearDown()
    }

    func testTheRefusalNamesItselfAndOffersOnlyItsTwoWaysOut() throws {
        let app = try LaunchedApp.launch(dataRoot: root,
                                         projectRoot: try BrokenWorld.aCheckout(in: root))
        print("UnreadableStoreAlertUITests:\n\(AlertOnScreen.describe(app))")

        XCTAssertTrue(AlertOnScreen.showing(AlertTitle.storeUnavailable, in: app),
                      "the refusal to open the events is not on screen. "
                      + AlertOnScreen.describe(app))

        // The pairing is the whole of #855: a title over the wrong buttons is
        // two halves of one screen each reading as correct. So the buttons are
        // asserted against this title, not merely counted.
        let (labels, fromAlert) = AlertOnScreen.buttons(in: app)
        XCTAssertTrue(labels.contains("Try Again"),
                      "no Try Again on the refusal. Buttons "
                      + "(fromAlert=\(fromAlert)): \(labels)")
        XCTAssertTrue(labels.contains("Quit PostRoll"),
                      "no Quit PostRoll on the refusal. Buttons "
                      + "(fromAlert=\(fromAlert)): \(labels)")
        if fromAlert {
            XCTAssertFalse(labels.contains("OK"),
                           "the refusal carries an OK, which is the dismissible "
                           + "alert's button on the one alert that must not be "
                           + "dismissible: \(labels)")
        }

        // It refuses to be dismissed, which is the whole of it. The events are
        // still on disk and letting Dan past would show him an empty library
        // that quietly discards everything he types into it.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        usleep(2_000_000)
        XCTAssertTrue(app.staticTexts[AlertTitle.storeUnavailable].exists,
                      "Escape dismissed the one alert that must not be "
                      + "dismissible. " + AlertOnScreen.describe(app))
    }
}

// MARK: - A code folder that is not a checkout

final class BrokenCodeFolderAlertUITests: XCTestCase {

    private let root = LaunchedApp.scratchRoot("no-code-folder")

    override func setUpWithError() throws {
        continueAfterFailure = true
        try BrokenWorld.store("[]", in: root)
    }

    override func tearDown() {
        LaunchedApp.terminateEveryCopy()
        BrokenWorld.remove(root)
        super.tearDown()
    }

    func testTheCodeFolderAlertNamesTheFolderAndIsDismissible() throws {
        let folder = try BrokenWorld.notACheckout(in: root)
        let app = try LaunchedApp.launch(dataRoot: root, projectRoot: folder)
        print("BrokenCodeFolderAlertUITests:\n\(AlertOnScreen.describe(app))")

        XCTAssertTrue(AlertOnScreen.showing(AlertTitle.projectRoot, in: app),
                      "the code folder alert is not on screen. "
                      + AlertOnScreen.describe(app))

        // The message names the folder, which is what makes it actionable: an
        // alert saying the code folder is wrong without saying which folder it
        // looked in leaves nothing to do about it (L80).
        let named = AlertOnScreen.words(in: app).contains { $0.contains("not-a-checkout") }
        XCTAssertTrue(named,
                      "nothing on screen names the folder the app looked in. "
                      + AlertOnScreen.describe(app))

        let (labels, fromAlert) = AlertOnScreen.buttons(in: app)
        XCTAssertTrue(labels.contains("OK"),
                      "this alert is dismissible and has no way out. Buttons "
                      + "(fromAlert=\(fromAlert)): \(labels)")
    }
}

// MARK: - Both at once, which is where #855 was found

final class BothBrokenAlertUITests: XCTestCase {

    private let root = LaunchedApp.scratchRoot("both-broken")

    override func setUpWithError() throws {
        continueAfterFailure = true
        try BrokenWorld.store("[]", in: root, readable: false)
    }

    override func tearDown() {
        LaunchedApp.terminateEveryCopy()
        BrokenWorld.remove(root)
        super.tearDown()
    }

    func testTheRefusalTakesTheScreenFromTheWarningBehindIt() throws {
        let folder = try BrokenWorld.notACheckout(in: root)
        let app = try LaunchedApp.launch(dataRoot: root, projectRoot: folder)
        print("BothBrokenAlertUITests:\n\(AlertOnScreen.describe(app))")

        // Both launch checks fire on this world and both want the screen within
        // the same second. The refusal wins whichever finished first, because it
        // is the one that cannot be waved away to reveal what it was hiding.
        XCTAssertTrue(AlertOnScreen.showing(AlertTitle.storeUnavailable, in: app),
                      "the refusal is not the alert on screen, so the queue gave "
                      + "the window to the warning it displaces. "
                      + AlertOnScreen.describe(app))
        XCTAssertFalse(app.staticTexts[AlertTitle.projectRoot].exists,
                       "the code folder warning is on screen alongside the "
                       + "refusal, which is the collision #846 removed. "
                       + AlertOnScreen.describe(app))

        // ── the whole of #855, which step 6 of the hand check presses by hand ──
        //
        // Repair the store underneath the refusal and press Try Again. One
        // button press then makes two changes: the refusal is torn down and the
        // warning queued behind it is promoted. SwiftUI's report of the alert
        // it tore down arrives AFTER that, and unaddressed it lands on the
        // warning nobody has seen yet and dismisses it, recorded as dismissed
        // so it never comes back.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: root.appendingPathComponent("events.json").path)

        XCTAssertTrue(AlertOnScreen.press("Try Again", in: app),
                      "there was no Try Again to press on the refusal")

        XCTAssertTrue(AlertOnScreen.gone(AlertTitle.storeUnavailable, in: app),
                      "Try Again did not clear the refusal, so the repair was "
                      + "not seen. " + AlertOnScreen.describe(app))
        XCTAssertTrue(AlertOnScreen.showing(AlertTitle.projectRoot, in: app, within: 10),
                      "the code folder warning did not take the screen the "
                      + "refusal left. That is #855: one press made two changes "
                      + "and swallowed the alert nobody had seen. "
                      + AlertOnScreen.describe(app))
    }
}
