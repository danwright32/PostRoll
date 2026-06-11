import XCTest

/// UI smoke test (issue #33). Drives the real app against a sandboxed data
/// directory via POSTROLL_DATA_DIR (issue #34), so nothing here can touch
/// live data. Scope is deliberately narrow: launch, create an event, see it
/// in the sidebar, relaunch, see it persisted. Flows that shell out to
/// Python or write UserDefaults are out of scope.
final class PostRollUITests: XCTestCase {

    func testCreateEventPersistsAcrossRelaunch() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostRollUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let app = XCUIApplication()
        app.launchEnvironment["POSTROLL_DATA_DIR"] = sandbox.path
        app.launch()

        // Fresh sandbox: the welcome pane offers New Event
        let newEvent = app.buttons["New Event"]
        XCTAssertTrue(newEvent.waitForExistence(timeout: 10), "welcome New Event button")
        newEvent.click()

        let nameField = app.textFields["Event name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "event name field")
        nameField.click()
        nameField.typeText("Smoke Test Show")

        let orgField = app.textFields["Organization"]
        orgField.click()
        orgField.typeText("Smoke Org")

        app.buttons["Create Event"].click()

        // The event lands in the sidebar
        XCTAssertTrue(
            app.staticTexts["Smoke Test Show"].waitForExistence(timeout: 5),
            "created event appears in the sidebar"
        )

        // Relaunch: the event must come back from the sandboxed events.json.
        // Wait for full termination and use a fresh XCUIApplication: reusing
        // the old proxy can attach to the new instance before its
        // accessibility tree is ready, which reads as a Disabled app.
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 10)

        let relaunched = XCUIApplication()
        relaunched.launchEnvironment["POSTROLL_DATA_DIR"] = sandbox.path
        relaunched.launch()
        relaunched.activate()
        XCTAssertTrue(relaunched.windows.firstMatch.waitForExistence(timeout: 10))
        // With no selection restored, the name lives in the sidebar row,
        // whose content SwiftUI flattens into the cell label rather than a
        // distinct staticText. Match by label across any element type.
        let row = relaunched.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Smoke Test Show"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "event persists across relaunch")

        // The sandbox, not the live store, took the write
        let sandboxStore = sandbox.appendingPathComponent("events.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandboxStore.path))
    }
}
