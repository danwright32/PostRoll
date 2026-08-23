import Foundation

/// Whether the copy of PostRoll that answered a link is the one meant to
/// (#840).
///
/// More than one PostRoll.app exists on this Mac, and that is not hypothetical:
/// when #840 was filed, `lsregister` held 14 registrations for the name and
/// four of the bundles were still on disk (the installed copy, a Debug and a
/// Release build product, and one in Xcode's DerivedData). While PostRoll
/// answered no URLs that cost nothing. Declaring `postroll://` makes every one
/// of them a candidate, and which one macOS picks is not a decision this code
/// gets to make.
///
/// So this does not try to make the right copy win. It makes the wrong one
/// visible. A Debug build answering a link reads its own events store and
/// writes there, and without this the only symptom is an event that later
/// cannot be found, with nothing anywhere saying why.
///
/// The 2026-08-04 Overture incident is the same shape, and it is also why the
/// comparison here takes the answering bundle as an ARGUMENT: a check whose two
/// sides come from one lookup can only confirm that lookup is consistent, never
/// that it is correct (L70).
enum AnsweringCopy {

    /// Where the copy meant to answer links lives, which is where
    /// `build-install.sh` puts it.
    static let installedPath = "/Applications/PostRoll.app"

    /// What to say about the copy that answered, or nil when it is the right
    /// one.
    ///
    /// Paths are standardized and their symlinks resolved before they are
    /// compared. Two spellings of one location taken for two different copies
    /// would warn on every link, and a warning that is always on is one nobody
    /// reads (L36).
    static func notice(answeredBy bundle: URL, installedAt: String = installedPath) -> String? {
        let answered = settled(bundle)
        let meant = settled(URL(fileURLWithPath: installedAt))
        guard answered != meant else { return nil }

        return "This link was answered by \(answered), not by the installed PostRoll at "
            + "\(meant). That copy has its own events, so anything created here will not be "
            + "in the app you normally open. Quit this copy and open the installed one."
    }

    private static func settled(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath()
            .path(percentEncoded: false)
    }
}
