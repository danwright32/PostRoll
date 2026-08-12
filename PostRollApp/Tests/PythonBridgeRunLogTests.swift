import XCTest

/// #90: every Python subprocess wrote its stderr into ONE shared log, and each
/// run began by truncating that log to its last 500 lines with
/// `tail > tmp && mv tmp log`.
///
/// PythonBridge is an actor but runProcess suspends, so calls interleave:
/// GenerationManager launches week generation and preview generation together
/// and SpeculativeReelRenderer can add a third. The `mv` swaps the inode under
/// a live run, so its appends go to an unlinked file and vanish, and the error
/// finally surfaced can belong to a different operation entirely.
///
/// The fix is per-run isolation: each run owns a private stderr file, so no
/// run can lose or read another's output.
final class PythonBridgeRunLogTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runlog_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testEachRunGetsItsOwnLogFile() {
        let a = PythonBridgeLog.runLogURL(in: dir, marker: "aaa")
        let b = PythonBridgeLog.runLogURL(in: dir, marker: "bbb")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.deletingLastPathComponent().path, dir.path)
    }

    func testARunReadsItsOwnOutputAndNotAConcurrentRuns() throws {
        let mine  = PythonBridgeLog.runLogURL(in: dir, marker: "mine")
        let other = PythonBridgeLog.runLogURL(in: dir, marker: "other")
        try "my failure: bad photo path".write(to: mine, atomically: true, encoding: .utf8)
        try "unrelated failure: 413 too large".write(to: other, atomically: true, encoding: .utf8)

        let text = PythonBridgeLog.runOutput(runLog: mine, sharedLog: dir.appendingPathComponent("nope.log"),
                                             marker: "mine")

        XCTAssertTrue(text.contains("my failure"), text)
        XCTAssertFalse(text.contains("413"),
                       "a concurrent run's output must be unreachable, not merely unlikely")
    }

    func testAnEmptyRunLogFallsBackToTheSharedLog() throws {
        // The shell can fail before the redirect exists (a bad interpreter),
        // leaving the run log empty. That must degrade to the shared log
        // rather than to an empty error message.
        let mine = PythonBridgeLog.runLogURL(in: dir, marker: "mine")
        let shared = dir.appendingPathComponent("postroll.log")
        try "Running [mine]:\nzsh: command not found".write(to: shared, atomically: true, encoding: .utf8)

        let text = PythonBridgeLog.runOutput(runLog: mine, sharedLog: shared, marker: "mine")
        XCTAssertTrue(text.contains("command not found"), text)
    }

    // MARK: - rotation

    func testRotationKeepsTheMostRecentLines() throws {
        let shared = dir.appendingPathComponent("postroll.log")
        let lines = (1...50).map { "line \($0)" }.joined(separator: "\n")
        try lines.write(to: shared, atomically: true, encoding: .utf8)

        PythonBridgeLog.rotate(shared, keepingLines: 10)

        let kept = try String(contentsOf: shared, encoding: .utf8)
        XCTAssertTrue(kept.contains("line 50"))
        XCTAssertFalse(kept.contains("line 39"))
    }

    func testRotationLeavesAShortLogAlone() throws {
        let shared = dir.appendingPathComponent("postroll.log")
        try "only line".write(to: shared, atomically: true, encoding: .utf8)

        PythonBridgeLog.rotate(shared, keepingLines: 500)

        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), "only line")
    }

    func testRotationOnAMissingFileIsNotAnError() {
        PythonBridgeLog.rotate(dir.appendingPathComponent("absent.log"), keepingLines: 10)
    }

    func testAFinishedRunIsFoldedIntoTheSharedLogAndCleanedUp() throws {
        let mine = PythonBridgeLog.runLogURL(in: dir, marker: "mine")
        let shared = dir.appendingPathComponent("postroll.log")
        try "earlier entry".write(to: shared, atomically: true, encoding: .utf8)
        try "this run's stderr".write(to: mine, atomically: true, encoding: .utf8)

        PythonBridgeLog.foldIntoShared(runLog: mine, sharedLog: shared)

        let text = try String(contentsOf: shared, encoding: .utf8)
        XCTAssertTrue(text.contains("earlier entry"), "history must survive")
        XCTAssertTrue(text.contains("this run's stderr"), "the run must be readable afterwards")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path),
                       "per-run files must not accumulate")
    }

    func testFoldingConcurrentRunsKeepsBothWholly() throws {
        // The race the shared-log truncation lost: two runs finishing at once.
        let shared = dir.appendingPathComponent("postroll.log")
        FileManager.default.createFile(atPath: shared.path, contents: Data())

        let runs = (0..<8).map { i -> URL in
            let u = PythonBridgeLog.runLogURL(in: dir, marker: "run\(i)")
            try? "run \(i) said something".write(to: u, atomically: true, encoding: .utf8)
            return u
        }

        let group = DispatchGroup()
        for run in runs {
            group.enter()
            DispatchQueue.global().async {
                PythonBridgeLog.foldIntoShared(runLog: run, sharedLog: shared)
                group.leave()
            }
        }
        group.wait()

        let text = try String(contentsOf: shared, encoding: .utf8)
        for i in 0..<8 {
            XCTAssertTrue(text.contains("run \(i) said something"),
                          "run \(i) was lost to a concurrent fold")
        }
    }
}
