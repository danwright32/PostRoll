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
