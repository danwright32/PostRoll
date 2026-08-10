import Foundation

/// What the finished-generation screen is allowed to claim (#262).
///
/// Two facts the generator reported on every run and nothing read:
///
/// `complete` is the only thing separating a run that reached the end of the
/// week from one that was cut off. A cut-off run has days missing for no reason
/// the screen can otherwise see, so calling it "Content generated" is the app
/// claiming more than it measured.
///
/// `unrecognised_failures` is the verbatim text of a failure the cap detector
/// did not recognise. `cap_signals` ships observe-only and #258, which
/// calibrates it, cannot begin until a real cap's exact wording has been seen.
/// It was written into every result file and read by nobody, so capturing it
/// depended on somebody happening to read stderr.
enum RunOutcomeNotice {

    /// The headline for a finished run.
    static func headline(week: WeekGenerationResult?, failedDayCount: Int) -> String {
        if week?.complete == false { return "Stopped before finishing" }
        return failedDayCount > 0 ? "Partially generated" : "Content generated"
    }

    /// Whether the screen may show the reassuring filled checkmark.
    ///
    /// A run that did not finish gets the same hollow mark as one with failures:
    /// the difference between "done" and "not done" has to be visible at a
    /// glance, not only in the words underneath.
    static func isUnqualifiedSuccess(week: WeekGenerationResult?, failedDayCount: Int) -> Bool {
        failedDayCount == 0 && week?.complete != false
    }

    /// A note about failures the run could not classify, or nil when there were
    /// none.
    ///
    /// Nil rather than empty so this cannot render a blank box on every ordinary
    /// run, which is how a notice stops being read before the one time it
    /// matters.
    static func unfamiliarFailureNote(week: WeekGenerationResult?) -> String? {
        guard let week, week.hasUnrecognisedFailures else { return nil }
        let count = week.unrecognisedFailures.count
        let subject = count == 1 ? "one failure" : "\(count) failures"
        return "This run hit \(subject) the app did not recognise. They are "
             + "recorded word for word in the log. If the week stopped early or "
             + "behaved oddly, that text is what is needed to fix it."
    }
}
