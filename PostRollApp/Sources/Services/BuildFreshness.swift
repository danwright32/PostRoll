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
/// What the warning shows, in a shape a sheet can be presented from.
struct BuildBehind: Identifiable, Equatable {
    let builtAt: Date
    let latestCommit: Date
    let remedy: BuildFreshness.Remedy
    /// The checkout this verdict was reached against, carried rather than
    /// looked up again when the sheet spells its remedy command (#648). The
    /// verdict cannot exist without one, so carrying it keeps the sheet from
    /// having to cope with not knowing where the code is.
    let repo: URL

    var id: String { "\(builtAt.timeIntervalSince1970)-\(latestCommit.timeIntervalSince1970)" }
}

enum BuildFreshness {

    /// A build kicked off seconds before a commit is not a stale app, and a
    /// warning on that is one nobody believes.
    static let tolerance: TimeInterval = 60

    /// What actually has to happen to catch up (#312).
    ///
    /// Two different fixes, so two different sentences. Telling Dan to rebuild
    /// a checkout that is itself behind sends him round the loop and leaves the
    /// symptom exactly where it was, which reads as the rebuild not working.
    enum Remedy: Equatable {
        /// The checkout already holds the newest work; only the app is behind.
        case rebuild
        /// Work merged and has not reached this Mac, so a rebuild alone would
        /// produce another build missing the same thing.
        case pullThenRebuild
    }

    enum Verdict: Equatable {
        /// The running app was built at or after the newest commit.
        case current
        /// The running app was built before the newest commit, so it may be
        /// missing merged work.
        case behind(builtAt: Date, latestCommit: Date, remedy: Remedy)
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

    /// The verdict from the build time, the checkout, and what merged (#312).
    ///
    /// `remoteCommit` is `origin/main`'s commit time, which is read from a ref
    /// already on disk and costs nothing. A nil one is ordinary rather than a
    /// failure (a fresh clone, a machine that has never fetched, no origin at
    /// all), so it falls back to the checkout instead of refusing to answer:
    /// the local comparison still stands and is still worth making.
    ///
    /// Note what the remote half can and cannot see. `origin/main` is as fresh
    /// as the last fetch or push from this Mac, so it catches the ordinary case
    /// (work merged from a session here, then never pulled back) and cannot
    /// catch work merged from somewhere else that this Mac has not heard about.
    /// Fetching at launch would close that, and is deliberately not done here:
    /// it would put the network on the path to the window opening.
    static func verdict(builtAt: Date?, localCommit: Date?,
                        remoteCommit: Date?) -> Verdict {
        guard let builtAt else {
            return .cannotTell(reason: "the app's build time could not be read")
        }
        guard let localCommit else {
            return .cannotTell(
                reason: "the PostRoll code folder could not be read, so there is "
                      + "nothing to compare this build against")
        }

        let newest = max(localCommit, remoteCommit ?? localCommit)
        guard builtAt.addingTimeInterval(tolerance) < newest else { return .current }

        // The checkout being behind decides the fix, whether or not the app is
        // also behind the checkout: rebuilding without pulling first cannot
        // produce a build that has the merged work in it.
        let checkoutBehind = localCommit.addingTimeInterval(tolerance)
            < (remoteCommit ?? localCommit)
        return .behind(builtAt: builtAt, latestCommit: newest,
                       remedy: checkoutBehind ? .pullThenRebuild : .rebuild)
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
        commitTime(inRepo: repo, ref: "HEAD")
    }

    /// The branch work merges to, as this Mac last heard it.
    ///
    /// A remote-tracking ref sitting in `.git`, so reading it is free and works
    /// with no network. It is not a question asked of GitHub: it is as fresh as
    /// the last fetch or push from here.
    static func remoteCommitTime(inRepo repo: URL) -> Date? {
        commitTime(inRepo: repo, ref: "origin/main")
    }

    /// When a named commit was made, or nil for every reason the read can fail.
    ///
    /// One implementation for both refs, so a change to how the time is parsed
    /// or how a failure is treated cannot apply to one of them and not the
    /// other.
    static func commitTime(inRepo repo: URL, ref: String) -> Date? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "log", "-1", "--format=%ct", ref]
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
                localCommit: latestCommitTime(inRepo: repo),
                remoteCommit: remoteCommitTime(inRepo: repo))
    }

    /// What the warning says.
    ///
    /// Names both times, because "your app is old" without saying how old
    /// leaves Dan to work out whether it matters, and names what fixes it.
    ///
    /// Two endings, because there are two different situations and one sentence
    /// covering both would be wrong for one of them. When the merged work has
    /// not reached this Mac, a rebuild produces another build missing it, and a
    /// message that only said "rebuild" would send him round that loop with the
    /// symptom unchanged.
    static func message(builtAt: Date, latestCommit: Date, remedy: Remedy) -> String {
        let opening =
            "The PostRoll you are running was built \(when(builtAt)). The newest "
            + "change to the code is from \(when(latestCommit)), so this copy may "
            + "be missing work that has already shipped.\n\n"

        switch remedy {
        case .rebuild:
            return opening
                + "Run postroll in Terminal to rebuild and reinstall, then open "
                + "the app again."
        case .pullThenRebuild:
            return opening
                + "That change has not reached this Mac yet, so rebuilding on its "
                + "own would not pick it up. Run the command below in Terminal to "
                + "pull it, rebuild and reinstall, then open the app again."
        }
    }

    /// The one line to type, matching the fix.
    ///
    /// The pull names the folder rather than assuming the terminal is already
    /// in it, and quotes it, because a path with a space in it would otherwise
    /// silently pull in some other directory.
    static func command(for remedy: Remedy, repo: URL) -> String {
        switch remedy {
        case .rebuild:
            return "postroll"
        case .pullThenRebuild:
            return "cd \"\(repo.path)\" && git pull && postroll"
        }
    }

    /// A time written the way a person reads one.
    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date)
            ? "'today at' h:mm a" : "d MMMM 'at' h:mm a"
        return formatter.string(from: date)
    }
}
