import Foundation

/// The transport switch, mirrored from `SUBSCRIPTION_ENV` in
/// `postroll/ai/transport.py`. Swift cannot import it, so the name is restated
/// here and `tests/test_subscription_transport.py` asserts the two agree: a
/// silent mismatch would leave the paid-path override exporting a variable
/// nothing reads, which looks exactly like it working.
enum Transport {
    static let subscriptionEnv = "POSTROLL_USE_SUBSCRIPTION"

    /// The shell line that pins one run to the metered API (#257).
    ///
    /// Empty unless asked for, so an ordinary run keeps whatever the setting
    /// says. When Dan chooses to finish a capped week by paying, that choice
    /// has to hold for THAT run whatever the subscription switch is set to, or
    /// the button promises something it stops doing the moment the switch is on.
    static func overrideExport(forcePaidPath: Bool) -> String {
        forcePaidPath ? "export \(subscriptionEnv)=0" : ""
    }
}


/// Thrown when a run stopped at a usage cap rather than crashing (#262).
///
/// Carries the week itself, because the days that finished are real and already
/// paid for: losing them is the expensive half of getting this wrong. A plain
/// error would leave the caller with a message and nothing to save.
struct WeekGenerationHalted: Error {
    let week: WeekGenerationResult

    /// Why it stopped, in the generator's own words. Never the process's
    /// traceback: a message may claim only what its check measured (L11).
    var reason: String {
        (week.stoppedReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


/// Thrown when a run died with days already generated (#206, #262).
///
/// Not a halt: there is no cap and no choice to offer, so the error screen is
/// still the right screen. What is different is that the run left real work
/// behind. `generate_week` persists after every day so a kill at any point
/// keeps what finished, and the case it was written for is this one: the app's
/// own 1800s watchdog SIGTERMs the subprocess, which raises nothing, so the
/// results file has no stop reason and reads as an ordinary crash. Discarding
/// it threw away up to half an hour of paid captions.
struct WeekGenerationFailedWithPartial: Error, LocalizedError {
    let underlying: Error
    let week: WeekGenerationResult

    /// The failure Dan sees. The salvage is silent in the message: the days are
    /// on the screen behind it, and a message may claim only what it measured.
    var errorDescription: String? {
        (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
    }
}


/// A week that stopped at a usage cap rather than finishing or failing (#257).
///
/// `generate_week` halts the whole week when it recognises a subscription cap,
/// because every remaining day would fail the same way, and it saves everything
/// finished up to that point. It records why in `stopped_reason`.
///
/// A halted week is its own state. It is not a failure, because the days that
/// finished are real and usable, and it is not a success, because the rest never
/// ran. Presenting it as either one is wrong in a way Dan pays for: as a failure
/// he re-runs work he already has, and as a success he ships a half week.
///
/// There are exactly two ways forward, and both are his to choose. Nothing is
/// spent without him saying so, so finishing on the paid path is a deliberate
/// press that names its own cost rather than a silent fallback when the
/// allowance runs out.
struct HaltedWeek: Equatable {

    enum Choice: Equatable, CaseIterable {
        /// Keep what finished and come back after the allowance resets.
        case waitForReset
        /// Finish the rest now on the metered API, which costs money.
        case finishOnPaidPath

        var label: String {
            switch self {
            case .waitForReset:     return "Wait for the reset"
            case .finishOnPaidPath: return "Finish now on the paid API"
            }
        }

        var explanation: String {
            switch self {
            case .waitForReset:
                return "Everything already generated stays. Come back once the "
                     + "allowance resets and pick up the rest of the week."
            case .finishOnPaidPath:
                return "Generates the remaining days through the metered "
                     + "Anthropic API instead of the subscription. This spends "
                     + "money, per day generated."
            }
        }

        /// Whether choosing this costs money. Read by the surface so the paid
        /// route can be presented as the deliberate one, rather than the two
        /// sitting side by side as if they were equivalent.
        var spendsMoney: Bool { self == .finishOnPaidPath }
    }

    /// Why the run stopped, in the words the generator recorded.
    let reason: String
    /// The days that finished before the halt. Shown so the work does not look
    /// lost, which is the difference between a halt and a failure.
    let finishedDays: [DayName]

    var choices: [Choice] { [.waitForReset, .finishOnPaidPath] }

    /// One line for a surface that has no room for the halt screen's two
    /// buttons (the caption review banner).
    ///
    /// It still has to do the halt screen's job in miniature: say the work is
    /// not lost, and say where the way forward is. A halt rendered as a bare red
    /// error reads as a crash, and the answer to a crash is to run it all again,
    /// which is the one thing that costs Dan money he does not need to spend.
    var reviewBanner: String {
        let kept = finishedDays.isEmpty
            ? "Nothing had finished yet."
            : "\(finishedDays.map(\.displayName).joined(separator: ", ")) are saved."
        // The reason comes from Python and has two producers that punctuate
        // differently: the cap path writes a finished sentence, and the two fatal
        // paths write a bare `str(e)` with no terminator at all. Closed through
        // Sentence so the second kind stops running into the next sentence as
        // "connection reset by peer Sunday, Tuesday are saved." (#405).
        return "\(Sentence.closed(reason)) \(kept) Choose whether to wait for the reset "
             + "or finish on the paid API from the Generate screen."
    }

    /// The halted state for a week, or nil when the week did not halt.
    ///
    /// A blank reason counts as no halt: the generator writes the key on every
    /// save, so treating "present" as "halted" would put this screen in front of
    /// every completed week.
    static func from(_ week: WeekGenerationResult) -> HaltedWeek? {
        guard let raw = week.stoppedReason else { return nil }
        let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return nil }

        return HaltedWeek(
            reason: reason,
            finishedDays: DayName.allCases.filter { week[$0] != nil })
    }
}
