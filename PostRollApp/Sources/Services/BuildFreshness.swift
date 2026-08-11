import Foundation

/// Is the PostRoll Dan is running older than the code it was built from?
///
/// Work merges all week and the app in /Applications keeps running whatever it
/// was last built from. So a fix can be written, merged and completely
/// invisible, and the only symptom is the app behaving like the old one, which
/// reads as the fix not working rather than as the fix not being there.
///
/// Overture answers this from the command line
/// (`mac/scripts/check-release-freshness.sh`). Dan does not live in a terminal,
/// so PostRoll says it on screen, once at launch.
///
/// Build time against commit time, deliberately, rather than a commit hash
/// stamped into the bundle: it works on the app already installed today with no
/// rebuild, which is the app the question is about. The one blind spot is
/// honest and harmless: a rebuild with no new commits reads as current, which
/// it is.
/// The two times the warning shows, in a shape a sheet can be presented from.
struct BuildBehind: Identifiable, Equatable {
    let builtAt: Date
    let latestCommit: Date

    var id: String { "\(builtAt.timeIntervalSince1970)-\(latestCommit.timeIntervalSince1970)" }
}

enum BuildFreshness {

    /// A build kicked off seconds before a commit is not a stale app, and a
    /// warning on that is one nobody believes.
    static let tolerance: TimeInterval = 60

    enum Verdict: Equatable {
        /// The running app was built at or after the newest commit.
        case current
        /// The running app was built before the newest commit, so it may be
        /// missing merged work.
        case behind(builtAt: Date, latestCommit: Date)
        /// One of the two halves could not be read. Not the same as current:
        /// nothing was compared, and saying the app is up to date on the
        /// strength of a failed read is a clean bill of health nobody measured
        /// (LESSONS.md L98, L10).
        case cannotTell(reason: String)

        /// Whether this verdict is worth interrupting Dan for.
        ///
        /// Only `behind`. A popup that cannot say anything actionable is one he
        /// learns to dismiss, and the real warning goes with it (L36), so
        /// `cannotTell` goes to the log instead.
        var isWorthShowing: Bool {
            if case .behind = self { return true }
            return false
        }
    }

    /// The verdict from two times, either of which may be unreadable.
    static func verdict(builtAt: Date?, latestCommit: Date?) -> Verdict {
        guard let builtAt else {
            return .cannotTell(reason: "the app's build time could not be read")
        }
        guard let latestCommit else {
            return .cannotTell(
                reason: "the PostRoll code folder could not be read, so there is "
                      + "nothing to compare this build against")
        }
        if builtAt.addingTimeInterval(tolerance) < latestCommit {
            return .behind(builtAt: builtAt, latestCommit: latestCommit)
        }
        return .current
    }

    /// When a bundle's own executable was written.
    ///
    /// The executable rather than the bundle folder: copying an app around
    /// touches the folder, and the question is when this binary was built.
    static func buildTime(of bundle: Bundle = .main,
                          fileManager: FileManager = .default) -> Date? {
        guard let executable = bundle.executableURL,
              let attributes = try? fileManager.attributesOfItem(atPath: executable.path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// When the newest commit in the checkout was made, or nil if it cannot be read.
    ///
    /// nil for every reason a read can fail: no folder, not a repository, no git
    /// on the machine. They are all "nothing to compare against", and the
    /// verdict above turns that into its own answer rather than into good news.
    static func latestCommitTime(inRepo repo: URL) -> Date? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "log", "-1", "--format=%ct", "HEAD"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              // Parsed through one place that returns a value or nothing, so a
              // failed parse cannot land on the healthy side of the comparison
              // (LESSONS.md L50).
              let epoch = TimeInterval(text)
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// The verdict for the running app against the project checkout.
    static func check(bundle: Bundle = .main, repo: URL) -> Verdict {
        verdict(builtAt: buildTime(of: bundle),
                latestCommit: latestCommitTime(inRepo: repo))
    }

    /// What the warning says.
    ///
    /// Names both times, because "your app is old" without saying how old
    /// leaves Dan to work out whether it matters, and names the one command
    /// that fixes it. `postroll` is the same command the Help menu copies.
    static func message(builtAt: Date, latestCommit: Date) -> String {
        "The PostRoll you are running was built \(when(builtAt)). The newest "
        + "change to the code is from \(when(latestCommit)), so this copy may be "
        + "missing work that has already shipped.\n\n"
        + "Run postroll in Terminal to rebuild and reinstall, then open the app "
        + "again."
    }

    /// A time written the way a person reads one.
    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date)
            ? "'today at' h:mm a" : "d MMMM 'at' h:mm a"
        return formatter.string(from: date)
    }
}
