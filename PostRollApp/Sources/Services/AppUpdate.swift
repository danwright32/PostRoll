import Foundation

/// Updating PostRoll from inside PostRoll (#686).
///
/// The out of date sheet used to print a command and a Copy button. Everything
/// needed to run it was already here: the sheet knows which checkout the
/// verdict was about and which of the two remedies applies, so the only thing
/// it could not do was the one thing it asked Dan to do.
///
/// The work itself runs in `PostRollApp/update-postroll.sh`, deliberately
/// OUTSIDE this process. build-install.sh quits the running PostRoll before it
/// replaces /Applications/PostRoll.app and opens the new one afterwards, so
/// anything doing the update from in here would be killed halfway through its
/// own work. This half is therefore: what to run, where it reports, and how to
/// read back an ending that may well arrive when the app that started it no
/// longer exists.
enum AppUpdate {

    /// The updater's filename inside the checkout. One spelling, used by the
    /// plan and by the check that it is there.
    static let scriptPath = "PostRollApp/update-postroll.sh"

    /// Everything one press of the button decides, as a value, so what gets run
    /// can be asserted without running it.
    struct LaunchPlan: Equatable {
        let executable: URL
        let arguments: [String]
        /// Where the run reports the step it is on, read on a timer while the
        /// app is alive.
        let progressFile: URL
        /// Where it records how it ended, read at the next launch when it is
        /// not.
        let outcomeFile: URL
        /// Everything it said, for when the outcome's last lines are not
        /// enough.
        let logFile: URL
    }

    /// What to run for one verdict.
    ///
    /// The updater comes from the CHECKOUT, not from the running bundle: the
    /// app in /Applications is the old build by definition, and the script that
    /// knows how to make the new one is the one sitting next to the code the
    /// verdict was reached against.
    static func plan(repo: URL, remedy: BuildFreshness.Remedy,
                     layout: AppPaths.Layout) -> LaunchPlan {
        let script = repo.appendingPathComponent(scriptPath)
        var arguments = [
            script.path,
            "--repo", repo.path,
            "--progress", layout.updateProgressFile.path,
            "--outcome", layout.updateOutcomeFile.path,
            "--log", layout.updateLogFile.path,
        ]
        // Exactly when the written command says `git pull`, and held to that by
        // a test: a button that rebuilt without pulling, under a sentence
        // saying the change has not reached this Mac, would send Dan round the
        // loop `BuildFreshness.Remedy` exists to break.
        if remedy == .pullThenRebuild { arguments.append("--pull") }

        return LaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"),
                          arguments: arguments,
                          progressFile: layout.updateProgressFile,
                          outcomeFile: layout.updateOutcomeFile,
                          logFile: layout.updateLogFile)
    }

    enum LaunchFailure: LocalizedError, Equatable {
        /// The checkout holds no updater, so there is nothing to run. Named
        /// rather than left to bash, whose exit 127 would arrive with no
        /// outcome file at all and leave the sheet waiting forever (L110).
        case updaterMissing(path: String)

        var errorDescription: String? {
            switch self {
            case .updaterMissing(let path):
                return "PostRoll could not find its updater at \(path). "
                     + "The code folder this build points at is not one it can "
                     + "update from."
            }
        }
    }

    /// Start the update and stop watching it.
    ///
    /// Deliberately not awaited: the whole point is that it outlives this
    /// process. Its output goes nowhere rather than into a pipe, because the
    /// reader on the other end of a pipe dies with the app, and a child writing
    /// into a closed pipe is killed by SIGPIPE at the exact moment it is
    /// replacing /Applications/PostRoll.app. It writes its own log.
    static func launch(_ plan: LaunchPlan) throws {
        let script = plan.arguments.first ?? ""
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw LaunchFailure.updaterMissing(path: script)
        }

        for directory in [plan.progressFile, plan.outcomeFile, plan.logFile]
            .map({ $0.deletingLastPathComponent() }) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// How an update ended, as the updater recorded it.
    struct Outcome: Equatable, Decodable {
        var ok: Bool
        var exitCode: Int
        var phase: String
        var message: String
        var finishedAt: Date

        enum CodingKeys: String, CodingKey {
            case ok, phase, message
            case exitCode = "exit_code"
            case finishedAt = "finished_at"
        }

        init(ok: Bool, exitCode: Int, phase: String, message: String, finishedAt: Date) {
            self.ok = ok
            self.exitCode = exitCode
            self.phase = phase
            self.message = message
            self.finishedAt = finishedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = try c.decode(Bool.self, forKey: .ok)
            exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
            phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
            message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
            let seconds = try c.decodeIfPresent(Double.self, forKey: .finishedAt) ?? 0
            finishedAt = Date(timeIntervalSince1970: seconds)
        }
    }

    /// The recorded ending, or nil when there is not one to read.
    ///
    /// nil covers three states that are all "no answer": nothing has run, a run
    /// is still going, and the file was caught mid-write. None of them is a
    /// finished update, and none of them may be read as a successful one: an
    /// absent answer reported as a pass is the whole of L98.
    static func readOutcome(at url: URL) -> Outcome? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Outcome.self, from: data)
    }

    /// The headline for a failure, in a sentence Dan can act on.
    ///
    /// The phase is what carries the meaning. A red Swift suite, a compile
    /// error, a pull that would overwrite local changes and a missing toolchain
    /// are four different problems needing four different next steps, and "the
    /// update failed" is the right sentence for none of them (L11). The
    /// updater's own output goes alongside this rather than inside it, because
    /// it is many lines and this is one.
    static func failureMessage(_ outcome: Outcome) -> String {
        let phase = outcome.phase.trimmingCharacters(in: .whitespacesAndNewlines)
        let step = phase.isEmpty ? "starting up" : phase
        return "The update stopped during: \(step) (exit code \(outcome.exitCode))."
    }

    /// Why an update must not start right now, or nil when it may.
    ///
    /// Installing quits the app, so anything part way through loses whatever it
    /// has not written back yet. Refusing is the point; naming what to wait for
    /// is what makes the refusal something other than a dead button.
    static func busyReason(generating: Bool, readingPrograms: Bool,
                           exporting: Bool) -> String? {
        var work: [String] = []
        if generating { work.append("a week is still generating") }
        if readingPrograms { work.append("a program is still being read") }
        if exporting { work.append("an export is still running") }
        guard !work.isEmpty else { return nil }

        return "PostRoll closes and reopens to install the new version, so it "
             + "cannot update while \(list(work)). Wait for that to finish, then "
             + "press Update again."
    }

    /// "a and b", "a, b and c". Written out because the sentence above reads
    /// badly with a bare comma.
    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
