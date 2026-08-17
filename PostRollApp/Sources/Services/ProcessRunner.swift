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
    /// What the PROCESS itself wrote, as distinct from what the launcher shell
    /// wrote to the stderr pipe (#650).
    ///
    /// The script redirects Python's stderr into a log file, so the pipe
    /// normally carries only whatever the shell said before `exec`, which is
    /// nothing at all on a healthy run. Both can have content at once, and when
    /// they do they are describing different things: the shell speaks when the
    /// work never started, the process speaks when the work failed.
    var processOutput: (@Sendable () -> ProcessOutput)? = nil

    /// Where a piece of failure text came from, because that decides whether it
    /// can be trusted to be THIS run's (#90, #650).
    enum ProcessOutput: Equatable {
        /// From the run's own private log file. Definitely this run, so it is
        /// the failure itself and outranks anything the launcher said.
        case own(String)
        /// From a tail of the log every run appends to. May belong to another
        /// run, so it is worth reading only when there is nothing else at all.
        case sharedTail(String)
        /// Nothing was found to read.
        case none
    }

    /// Which text a failure should be diagnosed from.
    ///
    /// Pure and separate from the subprocess call so each combination can be
    /// built and seen, rather than being reachable only by arranging a real
    /// process to fail in a particular way (L151).
    static func diagnosisText(launcher: String, process: ProcessOutput) -> String {
        func present(_ s: String) -> Bool {
            !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch process {
        // The process spoke, so that is the failure. The launcher's line is
        // context around it and stays in the log rather than being classified:
        // folding the two together would let a stray shell warning match a
        // needle and rename somebody else's failure.
        case .own(let text) where present(text):
            return text
        // Possibly another run's, so only when there is nothing else.
        case .sharedTail(let text) where present(text) && !present(launcher):
            return text
        default:
            return launcher
        }
    }
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

        let readProcessOutput = processOutput
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
                            let launcher = String(data: data, encoding: .utf8) ?? ""
                            let stderr = Self.diagnosisText(
                                launcher: launcher,
                                process: readProcessOutput?() ?? .none)
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
