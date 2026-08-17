import Foundation

/// Whether PostRoll can reach its own code folder, asked once at launch (#652).
///
/// An app that cannot generate anything looks completely normal until somebody
/// tries: the events load, every screen draws, and the fault only surfaces
/// after a day has been picked and a button pressed. The information exists at
/// launch, so waiting until Dan has spent the effort is a choice rather than a
/// limitation.
///
/// Nothing here decides what a run does. `PythonBridge.preflight` is still what
/// refuses, and this reports the same condition earlier, in the same words: the
/// message comes from the failure a generation would raise rather than being
/// written a second time, because two sentences about one condition drift, and
/// the moment they disagree the person in front of them has to work out which
/// is telling the truth (L144).
enum LaunchProjectCheck {

    enum Outcome: Equatable {
        /// Generation is going to fail, and this is why.
        case unreachable(AppPaths.ProjectRootProblem)
        /// The checkout is there and usable.
        case ready(URL)
    }

    /// Pure, so each outcome can be built and seen rather than being reachable
    /// only by arranging a real machine to be in that state (L151).
    static func outcome(root: URL? = AppPaths.projectRoot,
                        fileManager: FileManager = .default) -> Outcome {
        if let problem = AppPaths.projectRootProblem(root, fileManager: fileManager) {
            return .unreachable(problem)
        }
        // Non-nil whenever the problem is nil: `projectRootProblem` answers
        // `.notRecorded` for a nil root, so this cannot be reached with one.
        guard let root else { return .unreachable(.notRecorded) }
        return .ready(root)
    }

    /// What the notice is headed. It names what will not work rather than the
    /// fault alone, because a heading naming only the fault leaves Dan to work
    /// out for himself whether it matters to him right now (L80).
    static let title = "PostRoll cannot generate anything"

    /// The body, taken from the failure a generation would raise so the two
    /// cannot disagree.
    static func message(_ problem: AppPaths.ProjectRootProblem) -> String {
        PythonBridgeError.projectRootUnavailable(problem).message(whileDoing: .generation)
    }

    /// It warns, it does not block. Everything that is not generation still
    /// works (events, photos, captions already written, the archive), so
    /// quitting him out or trapping him behind a modal would take away more
    /// than the fault itself does.
    static let isDismissible = true
}
