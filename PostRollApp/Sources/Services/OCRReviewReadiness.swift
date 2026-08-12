import Foundation

/// Whether the extracted program data is good enough to build a week on, and
/// what to say about it.
///
/// Lifted out of `OCRReviewView` (#396). Every sentence here is one Dan only
/// meets when a program came back thin or when auto-flagging died, which is
/// exactly the copy that goes unread: reaching those states means feeding the app
/// a bad program on purpose.
enum OCRReviewReadiness {

    /// What is missing from the extracted data, or nil when nothing is.
    ///
    /// Returns the reasons rather than a bool so the banner can name them. The
    /// same value decides the continue button's wording, so the button can never
    /// say "Looks Good" over a banner listing what is wrong.
    static func detectedIssues(performerCount: Int, pieceCount: Int) -> [String]? {
        var issues: [String] = []
        if performerCount == 0 {
            issues.append("No performers found. Check that the cast list is in your photos.")
        }
        if pieceCount == 0 {
            issues.append("No works or program listing found.")
        }
        return issues.isEmpty ? nil : issues
    }

    /// What the continue button says.
    ///
    /// Three states, because they mean three different things: there is work to
    /// do first, the data is thin and he is choosing to go anyway, or it is fine.
    static func confirmLabel(unresolvedFlagCount: Int, hasDetectedIssues: Bool) -> String {
        if unresolvedFlagCount > 0 {
            return "Resolve \(unresolvedFlagCount) issue\(unresolvedFlagCount == 1 ? "" : "s")"
        }
        return hasDetectedIssues ? "Continue Anyway" : "Looks Good"
    }

    /// Why the button is disabled, or what going ahead anyway costs.
    ///
    /// Never empty while the button is disabled: a greyed out control beside no
    /// explanation leaves the person with nothing connecting the two (L109).
    static func confirmHelp(unresolvedFlagCount: Int, hasDetectedIssues: Bool) -> String {
        if unresolvedFlagCount > 0 {
            return "Apply or dismiss each flagged issue above before continuing."
        }
        return hasDetectedIssues
            ? "Missing data may produce generic captions. You can add performers or works now, or revise captions after generation."
            : ""
    }

    /// Why the program's own text could not be used to check spelling (#209),
    /// with the instruction that follows from it.
    ///
    /// The reason is closed through `Sentence` because it comes from elsewhere and
    /// its punctuation is unknown here.
    static func visionSkippedMessage(_ reason: String) -> String {
        "Names were not spell-checked against the program. "
            + Sentence.closed(reason)
            + " Check performer names and handles carefully below."
    }

    /// Auto-flagging died, so nothing double-checked the extraction.
    ///
    /// This is where the missing stop was found by rendering the screen (#396):
    /// a library error ending in no punctuation ran straight into the next
    /// sentence as "connection reset by peer The data was extracted".
    static func flagErrorMessage(_ reason: String) -> String {
        "Auto-flagging didn't run: \(Sentence.closed(reason)) The data was extracted, "
            + "but Claude couldn't double-check it for issues. Review the sections below "
            + "manually before continuing."
    }
}
