import Foundation

/// What the window says when the code folder is not on a clean main (#664).
///
/// PostRoll generates with the code in the checkout rather than with anything
/// bundled, so a session left mid branch, or holding uncommitted edits, changes
/// what a generation produces while everything on screen looks normal. #661
/// records which commit ran, which answers the question afterwards. This says it
/// beforehand, which is when it can still be acted on.
///
/// Deliberately a notice and not a refusal: testing a change by generating with
/// it is the entire reason the checkout is ever off main.
enum CheckoutNotice {

    /// The icon and style the banner is drawn with, named here so the copy and
    /// the surface it lands on cannot be described in two places.
    static let icon = "arrow.triangle.branch"

    /// The dismiss control's label, spelled once (#696).
    ///
    /// A word rather than a bare cross: a control has to look like a control at
    /// rest, and an icon with no accessible name is something VoiceOver can only
    /// describe as a button (L20, L49).
    static let dismissLabel = "Dismiss"

    /// What to say, or nil when there is nothing worth saying.
    ///
    /// nil for a clean main, which is every ordinary day, and nil for a reading
    /// that failed. The second follows the build freshness check beside it: a
    /// notice that cannot say anything actionable is one that gets ignored, and
    /// the real warning goes with it (L36). The reason still reaches the log.
    static func message(for reading: CheckoutRevision.Reading,
                        mainBranch: String = "main") -> String? {
        guard case .known(_, let branch, let dirty) = reading else { return nil }

        let place: String?
        if branch == CheckoutRevision.detachedBranch {
            place = "is not on a branch"
        } else if branch != mainBranch {
            place = "is on a branch called \(branch) rather than \(mainBranch)"
        } else {
            place = nil
        }
        let unsaved = dirty ? "has changes that have not been saved to a branch" : nil

        let states = [place, unsaved].compactMap { $0 }
        guard !states.isEmpty else { return nil }

        // Three short sentences rather than one long one with two "and"s in it,
        // read cold off the rendered banner (L21): what the folder is for, what
        // state it is in, and what that means for the next thing he does.
        //
        // The last one names WHICH half (#692). It used to say "anything you
        // generate now runs that code", which is true of the pipeline and false
        // of the parts the app draws itself: the finished Wednesday collage is
        // composited by PostRoll and is frozen into this build. The banner is
        // read at the exact moment its claim is being relied on, so switching
        // to a branch to test a collage change and reading the old sentence
        // said the change was under test when it was not, and the output looked
        // like the branch failing to work.
        return "PostRoll generates using the code in your PostRoll folder. That "
             + "folder \(states.joined(separator: ", and ")). Captions, blog "
             + "posts and reels will use that code; what PostRoll draws itself, "
             + "like the finished Wednesday collage, still comes from this "
             + "build until you rebuild it."
    }
}
