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

    // MARK: - A failure is described in the language of the work that failed (#626)

    /// Every failure a caller can be shown, in one place, so a wording that
    /// names the wrong unit of work fails here rather than on a screen.
    private static var everyFailure: [(name: String, error: PythonBridgeError)] {
        [
            ("a run that produced nothing", .outputMissing),
            ("a run that timed out", .timedOut(seconds: 600)),
            ("an output nothing could read", .invalidOutput("the cover path was missing")),
            ("a rejected key",
             .scriptFailed(exitCode: 1,
                           stderr: "anthropic.AuthenticationError: invalid x-api-key")),
            ("an overloaded service",
             .scriptFailed(exitCode: 1, stderr: "Error code: 529 - overloaded_error")),
            ("a failure nothing recognised",
             .scriptFailed(exitCode: 1,
                           stderr: "RuntimeError: the page bundle was rejected")),
        ]
    }

    /// A failed program read is never described as generation (#626).
    ///
    /// The screen that reports a paid read did not work is headed "Couldn't
    /// read the program" since #622, and every sentence under it began
    /// "Generation failed" or "Generation finished", because `errorDescription`
    /// had one hardcoded noun and 16 throw sites across both reads and
    /// generation share it. Each sentence is correct where it was written and
    /// the contradiction exists only in the reading (L118).
    func testAFailedProgramReadIsNeverCalledGeneration() {
        for state in Self.everyFailure {
            let text = state.error.message(whileDoing: .programRead)
            XCTAssertFalse(text.lowercased().contains("generat"), """
                For \(state.name), a failed program read says: "\(text)"

                Generation is a different stage of this app, with its own screens and its \
                own stage pill, so this names the wrong unit of work on the one screen \
                that says a paid read did not work.
                """)
        }
    }

    /// No failure ever names a unit of work other than the one that failed.
    ///
    /// The general form of the rule above, which is what actually matters: a
    /// sentence may be silent about what was running, and several rightly are,
    /// because "The AI service is overloaded right now" is about the service
    /// rather than about the work and reads correctly whoever asked. What it
    /// may never do is name the WRONG one, which is the whole of #626.
    func testNoFailureNamesAUnitOfWorkOtherThanTheOneThatFailed() {
        for state in Self.everyFailure {
            for work in PythonBridgeWork.allCases {
                let text = state.error.message(whileDoing: work)
                for other in PythonBridgeWork.allCases where other != work && other != .other {
                    XCTAssertFalse(text.contains(other.subject), """
                        For \(state.name) while doing \(work), the failure says: "\(text)"

                        That names \(other.subject), which is a different part of this app \
                        with its own screens. The person reading it is told the wrong thing \
                        stopped.
                        """)
                }
            }
        }
    }

    /// And the two failures that describe the WORK itself do name it.
    ///
    /// These are the generic ones, the run produced nothing and the run ran out
    /// of time, where the sentence has nothing else to be about. If either
    /// stopped naming the work it would be back to saying "the operation",
    /// which is what sent somebody looking at the wrong screen.
    func testTheFailuresAboutTheWorkItselfNameIt() {
        for work in PythonBridgeWork.allCases {
            for error in [PythonBridgeError.outputMissing,
                          PythonBridgeError.timedOut(seconds: 600)] {
                let text = error.message(whileDoing: work)
                XCTAssertTrue(text.contains(work.subject), """
                    While doing \(work), the failure says "\(text)", which never says what \
                    was running.
                    """)
            }
        }
    }

    /// The default names no particular work, rather than guessing one (#626).
    ///
    /// `localizedDescription` is reached from dozens of places and cannot know
    /// what was running, so it has to be the SAFE answer rather than the common
    /// one. It used to say "Generation", which is right for one caller and wrong
    /// for every other, and a caller that forgets to say what it was doing got
    /// a confidently wrong noun instead of a vague one (L93).
    func testTheDefaultWordingGuessesNoParticularWork() {
        for state in Self.everyFailure {
            let text = state.error.localizedDescription
            XCTAssertFalse(text.lowercased().contains("generat"), """
                For \(state.name), the default wording says: "\(text)"

                Nothing at that call site knows generation was what failed, so a caller \
                that says nothing must not be handed a specific claim.
                """)
        }
    }

    /// A failure nobody recognised does not lead with a Python class name (#626).
    ///
    /// The unrecognised path shows the last line of stderr, which for a real
    /// traceback begins "RuntimeError:" or "ValueError:". That is the name of a
    /// type inside the program, in front of a photographer, at the moment
    /// something has already gone wrong.
    func testAnUnrecognisedFailureDoesNotLeadWithAnExceptionClass() {
        let error = PythonBridgeError.scriptFailed(
            exitCode: 1,
            stderr: "Traceback (most recent call last):\n"
                + "RuntimeError: the page bundle was rejected by the service")

        let text = error.message(whileDoing: .programRead)

        XCTAssertFalse(text.contains("RuntimeError"), """
            The failure reads: "\(text)"

            A person cannot act on the name of an exception class, and it is the first \
            thing they are shown.
            """)
        XCTAssertTrue(text.contains("the page bundle was rejected by the service"), """
            The failure reads: "\(text)"

            Stripping the class name must not take the only description of what happened \
            with it, or the message says less than it did.
            """)
    }

    /// The managers actually say what they were doing (#626, L3).
    ///
    /// Naming the work proves nothing on its own: the wording is only right if
    /// the code that catches the error passes it. A manager falling back to
    /// `localizedDescription` gets the neutral sentence, which is not WRONG,
    /// which is exactly why nothing would report it: the screen would quietly
    /// go back to saying "The run failed" and look fine.
    ///
    /// Scoped per file, and the rule really is file wide: each of these
    /// managers runs one kind of work, so a bare `localizedDescription` on a
    /// bridge error is an offence wherever in the file it sits.
    func testEachManagerNamesTheWorkItStarted() throws {
        let expected = [
            "Services/OCRManager.swift": "programRead",
            "Services/OCRRescan.swift": "programRead",
            "Services/GenerationManager.swift": "generation",
            "Services/ExportManager.swift": "export",
        ]

        for (relative, work) in expected {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/\(relative)")
            let code = SwiftSourceText.withoutComments(
                try String(contentsOf: url, encoding: .utf8))

            XCTAssertTrue(code.contains("whileDoing: .\(work)"), """
                \(relative) never says it was doing \(work), so every failure it shows \
                falls back to the neutral wording and the screen stops naming what \
                stopped.
                """)
        }
    }
}
