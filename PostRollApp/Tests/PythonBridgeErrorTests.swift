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
