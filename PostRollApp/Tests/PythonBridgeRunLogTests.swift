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

        let output = PythonBridgeLog.runOutput(runLog: mine, sharedLog: dir.appendingPathComponent("nope.log"),
                                               marker: "mine")

        // `.own` and not `.sharedTail`: which source it came from decides
        // whether it outranks what the launcher shell said (#650).
        guard case .own(let text) = output else {
            return XCTFail("this run's own file must be reported as its own, got \(output)")
        }
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

        let output = PythonBridgeLog.runOutput(runLog: mine, sharedLog: shared, marker: "mine")

        // Reported as a shared tail, deliberately: it may hold another run's
        // lines, so it must not be allowed to outrank the launcher's own words
        // the way this run's private file does (#650).
        guard case .sharedTail(let text) = output else {
            return XCTFail("a shared-log read must be reported as one, got \(output)")
        }
        XCTAssertTrue(text.contains("command not found"), text)
    }

    // MARK: - the launcher's own header is not the process speaking (#661)

    func testTheHeaderTheLauncherWroteIsNotDiagnosedAsTheProcessOutput() throws {
        // The run log always opens with a line this app echoed into it: the
        // time, the marker, what is about to run and, since #661, which commit
        // the checkout was on. None of that is the process's output, and
        // `.own` outranks everything the launcher said, so a run that wrote
        // nothing at all would be diagnosed from our own header.
        let mine = PythonBridgeLog.runLogURL(in: dir, marker: "mine")
        let shared = dir.appendingPathComponent("postroll.log")
        try "Running [mine] (commit 1a2b3c4 on main, clean): 'python3'"
            .write(to: mine, atomically: true, encoding: .utf8)
        try "zsh: no such file or directory".write(to: shared, atomically: true, encoding: .utf8)

        let output = PythonBridgeLog.runOutput(runLog: mine, sharedLog: shared, marker: "mine")

        guard case .sharedTail = output else {
            return XCTFail("a run log holding only our own header means the "
                           + "process said nothing, got \(output)")
        }
    }

    func testABranchNameInTheHeaderCannotBeReadAsTheFailure() throws {
        // Why the line above has to go: the header now carries a branch name,
        // which is whatever somebody typed. `fix-413-x` reads to the failure
        // classifier as an HTTP 413 with clean boundaries either side, and
        // would rename a 401 as "the photos are too large" (#650 by a new
        // door).
        let mine = PythonBridgeLog.runLogURL(in: dir, marker: "mine")
        try """
            Running [mine] (commit 1a2b3c4 on fix-413-x, clean): 'python3'
            anthropic.AuthenticationError: 401 unauthorized
            """.write(to: mine, atomically: true, encoding: .utf8)

        let output = PythonBridgeLog.runOutput(
            runLog: mine, sharedLog: dir.appendingPathComponent("nope.log"), marker: "mine")

        guard case .own(let text) = output else {
            return XCTFail("the process spoke, so this is its own output, got \(output)")
        }
        XCTAssertTrue(text.contains("401"), text)
        XCTAssertFalse(text.contains("413"),
                       "the launcher's header must not reach the classifier")
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
