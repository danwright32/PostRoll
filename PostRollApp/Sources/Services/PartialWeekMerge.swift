import Foundation

/// Folding a run's output onto the week already saved (#262).
///
/// Three shapes of run land here and they are not interchangeable:
///
/// - a **full run that finished** replaces the week outright;
/// - a **partial retry that finished** merges only the days it was asked for,
///   and clears the stop bookkeeping, because a recorded failure that outlives
///   its cause keeps reporting a problem that is fixed;
/// - a **run that stopped early**, at a usage cap or killed outright, merges
///   without erasing anything, because the days after the stopping point were
///   never attempted. They are `nil` because nothing ran, not because they came
///   back blank, and replacing the saved week would delete captions an earlier
///   run generated and Dan paid for (L5).
///
/// The three are one function rather than a chain of `if let` branches in the
/// caller, because that chain got the order wrong: it tested "is this a partial
/// retry" before "did this run stop early", so a halted retry took the ordinary
/// merge path and nil'd out precisely the days this type exists to protect.
enum PartialWeekMerge {

    /// How the run that produced `incoming` ended.
    enum Ending: Equatable {
        /// Reached the end of what it was asked to do.
        case finished
        /// Stopped early: a cap, or killed. Nothing after the stop was attempted.
        case stoppedEarly
    }

    /// The week to save.
    ///
    /// - Parameter onlyDays: the day keys a partial retry was scoped to, or nil
    ///   for a full run. Ignored when the run stopped early: a run that stopped
    ///   did not necessarily cover its own scope, so its scope says nothing
    ///   about which days it is entitled to overwrite.
    static func merged(existing: WeekGenerationResult?,
                       incoming: WeekGenerationResult,
                       onlyDays: Set<String>?,
                       ending: Ending) -> WeekGenerationResult {
        if ending == .stoppedEarly {
            return applying(incoming, onto: existing)
        }
        guard let onlyDays, var week = existing else {
            // A full run that finished is the whole answer.
            var full = incoming
            full.complete = true
            full.stoppedReason = nil
            return full
        }

        for key in onlyDays {
            if key == "blog" {
                week.blog = incoming.blog
            } else if let day = DayName(rawValue: key) {
                week[day] = incoming[day]
            }
        }
        // Clear the retried days' errors, then carry over any new ones.
        for key in onlyDays { week.errors.removeValue(forKey: key) }
        week.errors.merge(incoming.errors) { _, new in new }
        week.unrecognisedFailures = incoming.unrecognisedFailures

        // This run reached its end, so the week is no longer stopped. Leaving
        // the old reason behind would keep the finished-generation screen saying
        // "Stopped before finishing" forever, and would put the paid-re-run
        // screen in front of the next unrelated failure carrying last week's cap
        // message: a stored failure has to stop reading as current when its
        // cause is gone, not only when the same run repeats.
        week.complete = true
        week.stoppedReason = nil
        return week
    }

    /// Everything the stopped run produced, over everything already there.
    ///
    /// The stopped run's own bookkeeping always wins, because it describes THIS
    /// run: a week that stopped is not complete, whatever the previous save
    /// said.
    static func applying(_ halted: WeekGenerationResult,
                         onto existing: WeekGenerationResult?) -> WeekGenerationResult {
        guard var merged = existing else {
            // Nothing to merge onto, but the invariant still holds: a week that
            // stopped did not finish. Asserting it here rather than trusting the
            // incoming value means a payload that arrives without `complete`
            // (an older build, a hand-made fixture) cannot read as finished.
            var first = halted
            first.complete = false
            return first
        }

        for day in DayName.allCases where halted[day] != nil {
            merged[day] = halted[day]
        }
        if halted.blog != nil { merged.blog = halted.blog }

        // Errors from this run replace same-key errors from the last one, and
        // errors for days this run never reached are left alone rather than
        // cleared: nothing was learned about them.
        merged.errors.merge(halted.errors) { _, new in new }
        merged.warnings.merge(halted.warnings) { _, new in new }

        merged.stoppedReason = halted.stoppedReason
        merged.complete = false
        merged.unrecognisedFailures = halted.unrecognisedFailures
        return merged
    }
}
