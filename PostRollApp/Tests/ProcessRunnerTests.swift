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
                                   logFallback: { "Traceback: the real reason" })

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

    func testTheLogTailIsNotUsedWhenStderrSaidSomething() async {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "echo 'the real reason' >&2; exit 1"],
                                   timeout: 10,
                                   logFallback: { "an older, unrelated log entry" })

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

/// #100: the watchdog sent one SIGTERM and moved on. A child that traps or
/// ignores it, or is wedged in an uninterruptible syscall, survived the
/// "stopped after 30 minutes" error and kept running, competing for CPU and
/// still holding the shared reel output a later render writes.
///
/// Real SIGTERM-trapping scripts, because the whole point is what the OS
/// actually does; a mock could only confirm the assumption being tested.
final class ProcessRunnerKillEscalationTests: XCTestCase {

    /// A pid that has fully exited (and been reaped) answers ESRCH.
    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func waitUntil(_ deadline: TimeInterval,
                           _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testAProcessIgnoringSIGTERMIsKilledWithinTheGraceWindow() async {
        // Traps SIGTERM and keeps going: exactly the case one terminate() call
        // cannot handle.
        let script = "trap '' TERM; while :; do sleep 0.1; done"
        var runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", script],
                                   timeout: 0.5)
        runner.killGrace = 1.0

        let started = Date()
        do {
            try await runner.run()
            XCTFail("a wedged process must not resolve as success")
        } catch let error as PythonBridgeError {
            guard case .timedOut = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
        } catch {
            XCTFail("expected PythonBridgeError, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "SIGKILL must follow the grace period, not wait forever")
    }

    func testAGrandchildDiesWithTheProcessItWasLaunchedFrom() async {
        // The real shape: python exec'd by the shell, ffmpeg launched by
        // python. Killing only the direct child orphans the grandchild, which
        // keeps writing the shared reel output.
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr_grandchild_\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let script = """
        /bin/sh -c 'echo $$ > \(pidFile.path); trap "" TERM; while :; do sleep 0.1; done' &
        trap '' TERM
        while :; do sleep 0.1; done
        """
        var runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", script],
                                   timeout: 1.0)
        runner.killGrace = 1.0

        try? await runner.run()

        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let grandchild = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return XCTFail("the grandchild never recorded its pid")
        }

        let died = await waitUntil(6) { !self.isAlive(grandchild) }
        XCTAssertTrue(died,
                      "grandchild \(grandchild) outlived the run it belonged to")
    }

    func testAWellBehavedProcessStillExitsOnTheFirstSignal() async {
        // The escalation must not change the ordinary case: SIGTERM is tried
        // first, and a process that honours it is never SIGKILLed.
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sleep"),
                                   arguments: ["30"],
                                   timeout: 0.5)
        do {
            try await runner.run()
            XCTFail("expected the timeout")
        } catch let error as PythonBridgeError {
            guard case .timedOut = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
        } catch {
            XCTFail("expected PythonBridgeError, got \(error)")
        }
    }

    func testTheContinuationResumesExactlyOnceUnderEscalation() async {
        // Resuming a continuation twice traps. The escalation adds a second
        // signal path, so this pins that it still resolves once.
        let script = "trap '' TERM; while :; do sleep 0.1; done"
        var runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", script],
                                   timeout: 0.3)
        runner.killGrace = 0.3

        for _ in 0..<3 {
            do { try await runner.run(); XCTFail("expected a timeout") }
            catch { /* one resolution per run, no trap */ }
        }
    }
}
