import Foundation

/// Which code a generation actually ran (#661).
///
/// The app does not bundle the Python. `PythonBridge.runProcess` cd's into the
/// recorded checkout and runs it from the WORKING TREE, so what a paid run
/// executes is whatever is checked out at that moment: main, a half-finished
/// branch, a rebase in flight, or a tree with uncommitted edits. Nothing
/// recorded which, so a surprising output was diagnosed against code that may
/// never have run.
///
/// It nearly mattered on 2026-08-17: during #656 the pinned text renderer
/// existed only on a feature branch while the rebuilt Python environment was
/// already live, so switching the checkout back to main would have rendered
/// type differently with nothing indicating it.
///
/// This is a reading taken at the top of a run and written into the log. It is
/// deliberately not a gate: refusing to run on a dirty tree would stop the one
/// person the app exists for from working while testing a change.
enum CheckoutRevision {

    /// What the checkout was, or why that could not be established.
    ///
    /// `unknown` is its own case rather than a blank: a header that quietly
    /// said nothing would be indistinguishable from a clean checkout on main,
    /// which is the reading that needs no explanation (L11).
    enum Reading: Equatable, Sendable {
        case known(commit: String, branch: String, dirty: Bool)
        case unknown(reason: String)
    }

    /// How long git gets before the run stops waiting for it.
    ///
    /// A wait with no deadline cannot fail, it can only hang, and a hang here
    /// would hold up every generation with no message at all (L110). Losing the
    /// record is the right trade against losing the run.
    static let deadline: TimeInterval = 5

    /// One line for the log.
    ///
    /// Dirtiness is stated in words rather than left to the absence of "clean":
    /// somebody scanning the log for a reason cannot notice what is not written
    /// down.
    static func describe(_ reading: Reading) -> String {
        switch reading {
        case .known(let commit, let branch, let dirty):
            let state = dirty ? "with UNCOMMITTED CHANGES" : "clean"
            return oneLine("commit \(commit) on \(branch), \(state)")
        case .unknown(let reason):
            return oneLine("checkout revision unknown: \(reason)")
        }
    }

    /// The revision of the checkout a run is about to execute.
    ///
    /// Three reads rather than one parse of `git status --branch --porcelain`,
    /// because each answers on its own and a repository with no commits yet
    /// still has a branch. Any failure is reported as unknown rather than as a
    /// clean tree.
    static func read(inRepo repo: URL, timeout: TimeInterval = deadline) -> Reading {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .unknown(reason: "the code folder is not there: \(repo.path)")
        }
        guard let commit = git(["rev-parse", "--short", "HEAD"],
                               inRepo: repo, timeout: timeout) else {
            return .unknown(reason: "git could not name a commit in \(repo.path)")
        }
        guard let branch = git(["rev-parse", "--abbrev-ref", "HEAD"],
                               inRepo: repo, timeout: timeout) else {
            return .unknown(reason: "git could not name a branch in \(repo.path)")
        }
        // Empty output with a clean exit is the answer here, not a failure, so
        // this is the one read where "" and nil have to stay apart.
        guard let status = git(["status", "--porcelain"],
                               inRepo: repo, timeout: timeout) else {
            return .unknown(reason: "git could not say whether \(repo.path) has "
                                 + "uncommitted changes")
        }
        return .known(commit: commit,
                      branch: branch == "HEAD" ? "a detached HEAD" : branch,
                      dirty: !status.isEmpty)
    }

    private static func git(_ arguments: [String], inRepo repo: URL,
                            timeout: TimeInterval) -> String? {
        output(arguments: ["-C", repo.path] + arguments, timeout: timeout)
    }

    /// A command's stdout, or nil for every reason there is no answer.
    ///
    /// nil covers a failed launch, a non-zero exit and a command that outstayed
    /// its deadline, because all three mean the same thing to the caller: this
    /// was not measured. The executable is a parameter so the deadline itself
    /// can be tested against something that really does not return.
    static func output(of executable: URL = URL(fileURLWithPath: "/usr/bin/git"),
                       arguments: [String],
                       timeout: TimeInterval = deadline) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drained on another queue rather than after the wait: a pipe holds
        // about 64KB, and `git status` in a thoroughly dirty tree writes more
        // than that, so a reader that waited first would block the child on a
        // full pipe and then time out on a command that was working perfectly.
        let collected = Box(Data())
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.value = out.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        _ = read.wait(timeout: .now() + timeout)
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: collected.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The log entry is one line, and a reason read off git can be several.
    /// A second line in the run log is read back as another line of the
    /// process's own output.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: "; ")
    }

    /// A value written on one queue and read on another after it has signalled.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
