import XCTest

/// The subprocess plumbing behind every generation, OCR and export run had no
/// coverage at all, including the three paths that only execute when something
/// has gone wrong: the watchdog timeout, a cancelled Swift task, and an exit
/// whose stderr is empty because Python's output went to the shared log (#86).
///
/// These run real (tiny) executables rather than a mock, because a mock here
/// could only confirm assumptions about Process rather than test them.
final class ProcessRunnerTests: XCTestCase {

    func testASuccessfulRunReturnsWithoutThrowing() async throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "exit 0"],
                                   timeout: 10)

        try await runner.run()
    }

    func testATimeoutKillsTheProcessAndReportsTheLimit() async {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sleep"),
                                   arguments: ["30"],
                                   timeout: 0.5)

        let started = Date()
        do {
            try await runner.run()
            XCTFail("a wedged process must not resolve as success")
        } catch let error as PythonBridgeError {
            guard case .timedOut(let seconds) = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(seconds, 0.5, accuracy: 0.001)
        } catch {
            XCTFail("expected PythonBridgeError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20,
                          "the watchdog has to kill it, not wait for it to finish")
    }

    func testANonzeroExitCarriesItsExitCodeAndStderr() async {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "echo 'boom' >&2; exit 3"],
                                   timeout: 10)

        do {
            try await runner.run()
            XCTFail("a nonzero exit is a failure")
        } catch let error as PythonBridgeError {
            guard case .scriptFailed(let code, let stderr) = error else {
                return XCTFail("expected scriptFailed, got \(error)")
            }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(stderr.contains("boom"), stderr)
        } catch {
            XCTFail("expected PythonBridgeError, got \(error)")
        }
    }

    func testAnEmptyStderrFallsBackToTheLogTail() async {
        // The real script redirects Python's stderr into the shared log, so the
        // pipe is empty on failure and the traceback is only in the log.
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "exit 1"],
                                   timeout: 10,
                                   processOutput: { .own("Traceback: the real reason") })

        do {
            try await runner.run()
            XCTFail("a nonzero exit is a failure")
        } catch let error as PythonBridgeError {
            guard case .scriptFailed(_, let stderr) = error else {
                return XCTFail("expected scriptFailed, got \(error)")
            }
            XCTAssertEqual(stderr, "Traceback: the real reason",
                           "an empty stderr must not become an empty error message")
        } catch {
            XCTFail("expected PythonBridgeError, got \(error)")
        }
    }

    // MARK: - Which text a failure is diagnosed FROM (#650)
    //
    // Two sources can supply it: the stderr pipe, which carries what the
    // LAUNCHER (the shell) said before `exec`, and the run's log, which carries
    // what the PROCESS said. They are not interchangeable, and which one is
    // trustworthy depends on where the log text came from:
    //
    //   * the run's OWN private file is definitely this run's process output,
    //     so it is the failure, and the shell's line is context around it.
    //   * a tail of the SHARED log may belong to another run entirely (#90), so
    //     it is only worth reading when the pipe said nothing at all.
    //
    // Collapsing that into "whichever is non-empty" hands every diagnosis to
    // the shell, which speaks exactly when the real work never started.

    func testTheProcessOwnOutputWinsOverWhateverTheShellSaid() async {
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'zsh:cd:2: no such file or directory: /gone' >&2; exit 1"],
            timeout: 10,
            processOutput: { .own("Traceback: TypeError in collage_planner.py") })

        do {
            try await runner.run()
            XCTFail("a nonzero exit is a failure")
        } catch let error as PythonBridgeError {
            guard case .scriptFailed(_, let stderr) = error else {
                return XCTFail("expected scriptFailed, got \(error)")
            }
            XCTAssertTrue(stderr.contains("TypeError"),
                          "the failure is what the PROCESS said: \(stderr)")
            XCTAssertFalse(stderr.contains("zsh:cd:"),
                           "the shell's line must not be classified as the failure: \(stderr)")
        } catch {
            XCTFail("expected PythonBridgeError, got \(error)")
        }
    }

    /// An empty own-file is not an answer. It means the process wrote nothing,
    /// so the shell's line is all there is and it is the honest thing to show.
    func testAnEmptyOwnOutputStillFallsBackToWhatTheShellSaid() async {
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'the shell could not start it' >&2; exit 1"],
            timeout: 10,
            processOutput: { .own("   ") })

        do {
            try await runner.run()
            XCTFail("a nonzero exit is a failure")
        } catch let error as PythonBridgeError {
            guard case .scriptFailed(_, let stderr) = error else {
                return XCTFail("expected scriptFailed, got \(error)")
            }
            XCTAssertTrue(stderr.contains("could not start it"), stderr)
        } catch {
            XCTFail("expected PythonBridgeError, got \(error)")
        }
    }

    func testASharedTailIsNotUsedWhenStderrSaidSomething() async {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "echo 'the real reason' >&2; exit 1"],
                                   timeout: 10,
                                   processOutput: { .sharedTail("an older, unrelated log entry") })

        do {
            try await runner.run()
            XCTFail("a nonzero exit is a failure")
        } catch let error as PythonBridgeError {
            guard case .scriptFailed(_, let stderr) = error else {
                return XCTFail("expected scriptFailed, got \(error)")
            }
            XCTAssertTrue(stderr.contains("the real reason"), stderr)
            XCTAssertFalse(stderr.contains("older, unrelated"), stderr)
        } catch {
            XCTFail("expected PythonBridgeError, got \(error)")
        }
    }

    func testCancellingTheTaskTerminatesTheChild() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-cancel-\(UUID().uuidString)")
        // Writes the marker only if it survives 30 seconds. A terminated child
        // never gets there, which is how the test proves SIGTERM landed.
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30; touch '\(marker.path)'"],
            timeout: 60)

        let task = Task { try await runner.run() }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the child kept running after its task was cancelled")
        try? FileManager.default.removeItem(at: marker)
    }

    func testAnUnlaunchableExecutableThrowsRatherThanHanging() async {
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/nonexistent/definitely-not-here"),
            arguments: [],
            timeout: 5)

        do {
            try await runner.run()
            XCTFail("a missing executable is a failure, not a hang")
        } catch {
            // Any error is acceptable; hanging forever is not.
        }
    }
}
