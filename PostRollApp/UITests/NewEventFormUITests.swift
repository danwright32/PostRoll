import AppKit
import XCTest

/// Whether Return commits a form Dan opened himself (#883, #848).
///
/// Step 3 of `docs/HAND-CHECK.md` presses this by hand, on the recorded grounds
/// that XCUITest never made the New Event form readable on the runner (#860,
/// and the comment on #848). That was measured before #877 found what the
/// harness actually does with text: an alert's words arrive as a static text's
/// VALUE with an EMPTY label, so a check reading the label reports the words
/// absent while they are plainly on screen. That is indistinguishable from a
/// window the harness cannot see into, and it is the mistake this file's
/// sibling shipped with on its first dispatch.
///
/// So the premise is re-measured rather than inherited (L61), and the outcome
/// is asserted twice over: the sheet going away, and the event reaching the
/// store on disk. The second is the one that matters. A sheet that closes
/// having created nothing looks exactly like a sheet that closed having created
/// something, and what #848 is about is whether an event was made.
final class NewEventFormUITests: XCTestCase {

    private let root = LaunchedApp.scratchRoot("new-event-form")

    override func setUpWithError() throws {
        // Every assertion is about one screen, so one failing must not hide the
        // rest: a run here is worth having for its full description of what the
        // form looked like.
        continueAfterFailure = true
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("events.json"))
    }

    override func tearDown() {
        LaunchedApp.terminateEveryCopy()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// The names in the store the app is writing to, or nil if it cannot be read.
    ///
    /// Read from disk rather than from the list on screen, because the question
    /// is whether an event was CREATED. A row appearing is evidence about the
    /// list; a record in events.json is the thing #848 exists to stop a stray
    /// keystroke producing.
    private func storedNames() -> [String]? {
        let file = root.appendingPathComponent("events.json")
        guard let data = try? Data(contentsOf: file),
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return events.compactMap { $0["name"] as? String }
    }

    /// Poll until the store holds `count` events, or the deadline passes.
    ///
    /// A save is not instant, so asking once immediately after a key press
    /// answers about the moment before the write rather than about the write
    /// (L106). The absence being waited for is asserted separately, with a
    /// fixed settle, because a poll for something that must never appear
    /// returns the instant it is called.
    @discardableResult
    private func waitForStore(toHold count: Int, within seconds: TimeInterval = 10) -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var names = storedNames() ?? []
        while Date() < deadline, names.count != count {
            usleep(200_000)
            names = storedNames() ?? []
        }
        return names
    }

    func testReturnCommitsAFormOpenedByHand() throws {
        // A checkout of its own, so the code folder alert cannot take the
        // screen: the runner has no venv/bin/python3 in its checkout, and an
        // alert in front of the window is a different test's subject.
        let app = try LaunchedApp.launch(dataRoot: root,
                                         projectRoot: try BrokenWorld.aCheckout(in: root))

        // Clicked rather than Cmd+N. A synthetic Cmd+W has been measured not to
        // take effect on this runner (#860), and clicking an on screen button
        // has been measured to work (#877), so the route that is known to
        // arrive is the one used. The command itself is step 2's question, not
        // this one's.
        let newEvent = app.buttons["New Event"].firstMatch
        XCTAssertTrue(newEvent.waitForExistence(timeout: 30),
                      "there is no New Event button to open the form with. "
                      + AlertOnScreen.describe(app))
        newEvent.click()

        // Printed on every run, pass or fail. The recorded reason this test did
        // not exist is that the form was unreadable, so what the tree holds
        // once it is open is the measurement even when everything passes.
        usleep(1_000_000)
        print("NewEventFormUITests, form open:\n\(AlertOnScreen.describe(app))")

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 20),
                      "no sheet came up, so the form did not open. "
                      + AlertOnScreen.describe(app))

        // The form is readable at all, which is the thing said to be impossible.
        XCTAssertTrue(sheet.buttons["Create Event"].exists,
                      "the form's Create Event button is not in the tree. "
                      + AlertOnScreen.describe(app))

        let name = sheet.textFields.firstMatch
        XCTAssertTrue(name.exists,
                      "the form has no readable text field, which is what #860 "
                      + "recorded and what this test exists to re-measure. "
                      + AlertOnScreen.describe(app))
        name.click()
        app.typeText("Return test")

        // Nothing yet. Asserting the store is empty BEFORE the Return is what
        // makes the assertion after it mean something: without this, a store
        // that already held an event would report success on a Return that did
        // nothing (L159).
        XCTAssertEqual(storedNames() ?? [], [],
                       "the store already holds events before Return was pressed")

        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        let names = waitForStore(toHold: 1)
        XCTAssertEqual(names, ["Return test"],
                       "Return did not create the event. The store holds \(names), "
                       + "and Create is meant to be the default action for a form "
                       + "opened by hand, which is Dan's everyday flow (#848)")

        XCTAssertFalse(sheet.exists,
                       "the event was created and the form is still on screen. "
                       + AlertOnScreen.describe(app))
    }
}
