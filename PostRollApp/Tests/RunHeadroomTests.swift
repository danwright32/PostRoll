import XCTest

/// #1479 (L743): a run that succeeds says how much of its time limit it used.
///
/// Every Python run gets one fixed limit, and a run that hits it is reported
/// as failed. Week generation's slowest recent run took 733 of 1800 seconds;
/// media rendering's duration was recorded nowhere, so nobody could say how
/// close the slowest passing week came. The run log now says, every time.
final class RunHeadroomTests: XCTestCase {

    func testAComfortableRunSaysItsShareOfTheLimit() {
        let line = PythonBridgeLog.headroomLine(elapsed: 412, limit: 1800)
        XCTAssertTrue(line.contains("412s of its 1800s limit"), line)
        XCTAssertFalse(line.contains("more than half"), line)
    }

    func testARunPastHalfItsLimitSaysSo() {
        let line = PythonBridgeLog.headroomLine(elapsed: 1000, limit: 1800)
        XCTAssertTrue(line.contains("more than half"), line)
    }

    func testTheLineIsAppendedToTheRunsOwnLog() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("run.log")
        try "[2026-10-03 12:00:00] Running\n".write(to: log, atomically: true, encoding: .utf8)

        PythonBridgeLog.appendHeadroom(to: log, elapsed: 61, limit: 1800)

        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("[2026-10-03 12:00:00] Running\n"), text)
        XCTAssertTrue(text.contains("61s of its 1800s limit"), text)
    }
}
