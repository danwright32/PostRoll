import XCTest

/// The update button is actually in the sheet, and reads the right files
/// (#686).
///
/// The logic under it is covered by AppUpdateTests and AppUpdateStateTests, and
/// all of that can be perfect while nothing on screen calls any of it: built is
/// not wired (L3). These read the sheet's own source, with comments stripped so
/// prose describing a button cannot satisfy a check for one (L103).
final class BuildBehindSheetWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func sheet() throws -> String {
        try source("Sources/Views/BuildBehindSheet.swift")
    }

    func testTheSheetStartsTheUpdateItself() throws {
        let code = try sheet()
        XCTAssertTrue(code.contains("appState.startUpdate("),
                      "the sheet no longer starts an update, so the button is "
                      + "either gone or does nothing: \(code)")
    }

    func testTheProgressShownIsTheUpdatesOwn() throws {
        // The updater writes one named file. A progress indicator pointed
        // anywhere else sits empty for the whole build while the update runs
        // perfectly, and nothing says so (L100).
        let code = try sheet()
        let flattened = code.split(whereSeparator: { $0 == "\n" || $0 == " " })
            .joined(separator: " ")
        XCTAssertNotNil(
            flattened.range(of: #"LongRunIndicator\(.*updateProgressFile"#,
                            options: .regularExpression),
            "the progress line is not reading the update's own step file: \(flattened)")
    }

    func testWorkInFlightIsCheckedBeforeAnUpdateStarts() throws {
        // Installing quits the app. A generation part way through loses
        // everything it has not written back, so the refusal is the point.
        let code = try sheet()
        XCTAssertTrue(code.contains("AppUpdate.busyReason("),
                      "nothing asks whether work is in flight, so pressing "
                      + "Update mid generation would quit the app over it")
        XCTAssertTrue(code.contains("busyReason: busyReason"),
                      "the answer is worked out and then not passed to the "
                      + "thing that would refuse on it")
    }

    func testTheWindowGivesTheSheetTheManagersItAsks() throws {
        // The sheet reads three managers out of its environment. A sheet is a
        // presentation, and a value it is never handed is a crash or an empty
        // answer at the exact moment the guard above matters.
        let window = try source("Sources/Views/MainWindowView.swift")
        guard let block = MainWindowSource.block(openedBy: "BuildBehindSheet(", in: window) else {
            return XCTFail("the window no longer presents the out of date sheet, "
                           + "so this guard has nothing to check")
        }
        for manager in ["generationManager", "ocrManager", "exportManager"] {
            XCTAssertTrue(block.contains(manager),
                          "\(manager) is never handed to the sheet that asks it "
                          + "whether work is in flight: \(block)")
        }
    }

    func testAFailedUpdateIsLookedForAtLaunch() throws {
        // The half that only matters when the app is not there to see it: an
        // update that reached the install step quit PostRoll, so the next
        // launch is where its failure has to surface (L164).
        let window = try source("Sources/Views/MainWindowView.swift")
        XCTAssertTrue(window.contains("appState.checkUpdateOutcome()"),
                      "nothing looks for how the last update ended, so a "
                      + "failure after the app was quit is never mentioned")
    }
}
