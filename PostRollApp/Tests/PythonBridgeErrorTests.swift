import XCTest

/// Pins the OCR/generation error-classification path. `runProcess` falls
/// back to reading the shared rolling log when the direct stderr pipe is
/// empty (the common case, since the exec'd process's stderr is redirected
/// straight into the log file). Without scoping that fallback to the
/// current invocation, a stray digit sequence in an unrelated OLDER log
/// entry (e.g. a UUID containing "413") can hijack `humanise()`'s substring
/// match and misreport a completely different failure. This is exactly
/// what happened on 2026-07-08: a real 401 "invalid x-api-key" error was
/// shown to the user as "photos too large".
final class PythonBridgeErrorTests: XCTestCase {

    // MARK: - PythonBridgeLog.scopedTail

    func testScopedTailReturnsOnlyLinesFromTheMarkerOnward() {
        let log = """
            [2026-07-04 09:48:54] Running: generate_media --output DD6C3413-5940-45B0-BC08-CE187E5167A8.json
            [2026-07-08 15:12:58] Running [MARKER-A]: ocr_program --image foo.png
            error: Anthropic API error: Error code: 401 - invalid x-api-key
            """
        let scoped = PythonBridgeLog.scopedTail(log, marker: "MARKER-A")
        XCTAssertFalse(scoped.contains("DD6C3413"), "must not leak unrelated older log entries")
        XCTAssertTrue(scoped.contains("MARKER-A"))
        XCTAssertTrue(scoped.contains("invalid x-api-key"))
    }

    func testScopedTailFallsBackToBoundedTailWhenMarkerMissing() {
        let log = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let scoped = PythonBridgeLog.scopedTail(log, marker: "NEVER-WRITTEN")
        XCTAssertFalse(scoped.contains("line 1\n"), "unbounded fallback would re-introduce the conflation bug")
        XCTAssertTrue(scoped.contains("line 60"))
    }

    // MARK: - PythonBridgeError.scriptFailed classification

    func testInvalidAPIKeyIsReportedAsAPIKeyProblem() {
        let stderr = "error: Anthropic API error: Error code: 401 - {'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}}"
        let message = PythonBridgeError.scriptFailed(exitCode: 1, stderr: stderr).errorDescription ?? ""
        XCTAssertTrue(message.contains("API key"), "got: \(message)")
        XCTAssertFalse(message.contains("too large"))
    }

    func testGenuineOversizedRequestIsStillReportedAsTooLarge() {
        let stderr = "error: Anthropic API error: Error code: 413 - request_too_large"
        let message = PythonBridgeError.scriptFailed(exitCode: 1, stderr: stderr).errorDescription ?? ""
        XCTAssertTrue(message.contains("too large"), "got: \(message)")
    }

    /// The end-to-end regression: an unrelated older log entry containing a
    /// UUID with "413" in it must not hijack classification of today's real
    /// 401 auth failure once the stderr fed to `scriptFailed` is properly
    /// scoped to the current invocation via its marker.
    func testMisdiagnosisBugIsFixedByScopingBeforeClassification() {
        let sharedRollingLog = """
            [2026-07-04 09:48:54] Running: generate_media --output DD6C3413-5940-45B0-BC08-CE187E5167A8.json
            [2026-07-08 15:12:58] Running [RUN-XYZ]: ocr_program --image screenshot.png
            error: Anthropic API error: Error code: 401 - {'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}}
            """
        let scopedStderr = PythonBridgeLog.scopedTail(sharedRollingLog, marker: "RUN-XYZ")
        let message = PythonBridgeError.scriptFailed(exitCode: 1, stderr: scopedStderr).errorDescription ?? ""
        XCTAssertTrue(message.contains("API key"), "got: \(message)")
        XCTAssertFalse(message.contains("too large"), "unrelated older \"413\" substring must not leak in, got: \(message)")
    }

    // MARK: - PythonBridgeError.invalidOutput carries a reason (#365)

    // Over twenty call sites in PythonBridge pass a written reason to
    // `invalidOutput`, and the switch that renders it never read the payload,
    // so every one of them arrived as the same generic sentence. The one
    // telling Dan exactly which step to go back to was the one that never
    // showed up.

    func testTwoDifferentCausesDoNotProduceTheSameMessage() {
        let noOCR = PythonBridgeError
            .invalidOutput("No OCR result. Complete the OCR step first.").errorDescription
        let noCover = PythonBridgeError
            .invalidOutput("Cover regeneration did not produce a cover path.").errorDescription

        XCTAssertNotEqual(noOCR, noCover,
                          "every call site writes a reason; they must not all render identically")
    }

    func testTheReasonTheCallSiteGaveIsWhatTheUserReads() {
        let message = PythonBridgeError
            .invalidOutput("No OCR result. Complete the OCR step first.").errorDescription ?? ""

        XCTAssertTrue(message.contains("Complete the OCR step first"), "got: \(message)")
    }

    func testTheMessageStillPointsAtTheLogs() {
        let message = PythonBridgeError.invalidOutput("Could not serialise current blog.")
            .errorDescription ?? ""

        XCTAssertTrue(message.contains(AppPaths.logsDirDisplayPath),
                      "the way to dig further has to survive alongside the reason, got: \(message)")
    }

    func testACallSiteThatGivesNoReasonStillSaysSomethingUseful() {
        // Not every throw has a sentence to offer, and an empty message would
        // be worse than the generic one.
        let message = PythonBridgeError.invalidOutput("   \n ").errorDescription ?? ""

        XCTAssertFalse(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(message.contains(AppPaths.logsDirDisplayPath), "got: \(message)")
    }
}

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
