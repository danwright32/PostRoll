import Foundation

/// Runs one subprocess to completion and turns how it ended into a
/// `PythonBridgeError`.
///
/// Extracted from PythonBridge so the paths that only execute when something
/// goes wrong can be exercised against real (tiny) executables: the watchdog
/// timeout, a cancelled Swift task, and an exit whose stderr is empty because
/// the output went to the shared log file (#86). None of them had any coverage,
/// which is exactly backwards: they are the paths nobody exercises by hand.
struct ProcessRunner {
    let executable: URL
    let arguments: [String]
    /// Full environment for the child, or nil to inherit this process's.
    var environment: [String: String]? = nil
    var currentDirectory: URL? = nil
    /// After this long the child is terminated and `.timedOut` is thrown. No
    /// invocation may hang the UI forever.
    var timeout: TimeInterval = 1800
    /// Consulted only when the child exits nonzero having written nothing to
    /// stderr, which is the normal case here because the script redirects
    /// Python's stderr into the shared log. Without it the error message would
    /// be an empty string.
    var logFallback: (@Sendable () -> String)? = nil
    /// How long a child gets to honour SIGTERM before it is SIGKILLed.
    ///
    /// One SIGTERM was the whole teardown, so a child that traps or ignores it
    /// survived the timeout error and kept running, competing for CPU and
    /// still holding the shared reel output a later render writes (#100).
    var killGrace: TimeInterval = 5

    /// Thread-safe latch so the watchdog's decision is readable from the
    /// catch below, which runs on a different thread.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false
        var fired: Bool {
            get { lock.withLock { _fired } }
            set { lock.withLock { _fired = newValue } }
        }
    }

    /// Every descendant of `pid`, deepest last, found by walking `pgrep -P`.
    ///
    /// `exec` makes the direct child the Python process itself, so ffmpeg is a
    /// grandchild. Signalling only the child orphans it, and an orphaned
    /// ffmpeg keeps writing the very output file the next render needs (#100).
    ///
    /// Not `kill(-pid)`: Process gives the child this app's own process group,
    /// so signalling the group would signal PostRoll itself.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var frontier = [pid]
        // Bounded so a pathological or cyclic tree cannot spin here.
        var guardCount = 0
        while let parent = frontier.first, guardCount < 64 {
            frontier.removeFirst()
            guardCount += 1
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            probe.arguments = ["-P", String(parent)]
            let pipe = Pipe()
            probe.standardOutput = pipe
            probe.standardError = FileHandle.nullDevice
            guard (try? probe.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            let kids = (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            found.append(contentsOf: kids)
            frontier.append(contentsOf: kids)
        }
        return found
    }

    /// SIGTERM the whole tree, then SIGKILL whatever is still alive after the
    /// grace period. Children are collected BEFORE the first signal: a dying
    /// parent stops being their parent, so `pgrep -P` would no longer find them.
    private static func tearDown(_ process: Process, grace: TimeInterval) {
        let pid = process.processIdentifier
        let tree = pid > 0 ? descendants(of: pid) : []

        if process.isRunning { process.terminate() }
        for child in tree { kill(child, SIGTERM) }

        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            // Deepest first, so a supervisor cannot restart what it watches.
            for child in tree.reversed() where kill(child, 0) == 0 {
                kill(child, SIGKILL)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    func run() async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let timedOut = TimeoutFlag()
        // terminate()/isRunning are safe cross-thread; the cancellation handler
        // below already relies on that from a nonisolated context.
        nonisolated(unsafe) let watchedProcess = process
        let grace = killGrace
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled, watchedProcess.isRunning {
                timedOut.fired = true
                Self.tearDown(watchedProcess, grace: grace)
            }
        }
        defer { watchdog.cancel() }

        let fallback = logFallback
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    // The handler must be installed before run(): a process that
                    // exits instantly (a bad module name, argparse exit 2) can
                    // otherwise terminate before the handler exists, and the
                    // continuation would hang forever.
                    process.terminationHandler = { p in
                        let status = p.terminationStatus
                        if status == 0 {
                            cont.resume()
                        } else {
                            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                            var stderr = String(data: data, encoding: .utf8) ?? ""
                            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                stderr = fallback?() ?? ""
                            }
                            cont.resume(throwing: PythonBridgeError.scriptFailed(
                                exitCode: status, stderr: stderr))
                        }
                    }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        cont.resume(throwing: error)
                    }
                }
            } onCancel: {
                // Same escalation as the watchdog: a cancelled task that only
                // ever sent SIGTERM left the same survivors behind.
                if process.isRunning { Self.tearDown(process, grace: grace) }
            }
        } catch {
            // A process the watchdog killed reports as a timeout, not as
            // whatever exit status SIGTERM happened to produce.
            if timedOut.fired { throw PythonBridgeError.timedOut(seconds: timeout) }
            throw error
        }
    }
}
