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
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled, watchedProcess.isRunning {
                timedOut.fired = true
                watchedProcess.terminate()
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
                if process.isRunning { process.terminate() }
            }
        } catch {
            // A process the watchdog killed reports as a timeout, not as
            // whatever exit status SIGTERM happened to produce.
            if timedOut.fired { throw PythonBridgeError.timedOut(seconds: timeout) }
            throw error
        }
    }
}
