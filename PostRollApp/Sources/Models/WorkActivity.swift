import Foundation

/// What the Dock should be saying about background work right now (#863).
enum DockWork: Equatable {
    /// Nothing is running. The Dock says nothing.
    case idle
    /// Something is running, and this is how long the longest of them has been
    /// going. The number is what makes it a STILL ALIVE signal rather than a
    /// working one: a mark that never changes is the same picture whether the
    /// run is progressing, wedged or dead.
    case working(seconds: Int)
}

/// Which owners of background work are running, and for how long.
///
/// A value type with no AppKit in it, so what the Dock should show can be
/// decided and tested without a Dock, in the same way `ModalQueue` keeps the
/// window's modal rule testable without a window.
///
/// Keyed per owner rather than counted. A single shared counter is the obvious
/// shape and it is wrong: every finishing job would drive it towards zero, so a
/// quick lookup ending beside a twenty minute generation would clear the Dock
/// while the generation was still going, and nothing would put it back.
struct WorkActivity {

    private var running: [ObjectIdentifier: Report] = [:]

    private struct Report {
        /// Weak, so an owner released mid run cannot hold the Dock open for the
        /// rest of the session with nothing able to clear it.
        weak var owner: AnyObject?
        var seconds: Int
    }

    /// What the Dock should show.
    ///
    /// The LONGEST run, not the newest. A short job starting beside a long one
    /// would otherwise reset the clock, and a number that keeps starting over
    /// reads as the work restarting rather than continuing.
    var state: DockWork {
        guard let longest = running.values.map(\.seconds).max() else { return .idle }
        return .working(seconds: longest)
    }

    /// Say how long this owner's longest run has been going, or nil when it has
    /// nothing running any more.
    ///
    /// One call for both directions, so an owner cannot report that it started
    /// without also being able to report that it stopped. Two methods called
    /// from two places is where the starting and the stopping become two paths
    /// that can disagree about what the Dock is showing (L16).
    mutating func report(_ owner: AnyObject, runningFor seconds: Int?) {
        let key = ObjectIdentifier(owner)
        guard let seconds else {
            running.removeValue(forKey: key)
            return
        }
        running[key] = Report(owner: owner, seconds: seconds)
    }

    /// Drop anything whose owner has been released.
    ///
    /// Its report can never be withdrawn by the owner itself, because there is
    /// no owner left to withdraw it.
    mutating func forgetOwnersThatWentAway() {
        running = running.filter { $0.value.owner != nil }
    }
}

/// What to say when a piece of background work ends.
///
/// Only the failure case for now, because the completions already had their
/// sentences and the failures had none at all: every manager's failure path
/// goes through `markFailed` and not one of them notified. With the window
/// closed that made a dead run, a running one and a finished one produce the
/// same evidence, which is none.
enum WorkOutcome {

    /// A run that stopped because something went wrong.
    ///
    /// `work` reads as what was being done ("generating Thursday"), so the body
    /// can name the step rather than making Dan open the app to find out which
    /// of seven things this was.
    static func failed(work: String, eventName: String, reason: String?) -> Announcement {
        Announcement(
            title: "\(eventName): \(work) stopped",
            // A reason when there is one. When there is not, the log is the
            // honest answer: saying nothing would be the same silence one level
            // down, and inventing a cause would be worse (L11).
            body: reason.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "It stopped without saying why. The log is in \(AppPaths.logsDirDisplayPath)."
        )
    }

    struct Announcement: Equatable {
        var title: String
        var body: String
    }
}
