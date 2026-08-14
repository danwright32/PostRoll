import Foundation

/// What the OCR screen says under the timer (#467).
///
/// "Taking longer than usual. Still working." was asserted from the wall clock.
/// The elapsed ticker keeps ticking whether or not the Python process is alive,
/// so a hung read looked exactly like a slow one until the 1800 second watchdog
/// fired, up to thirty minutes later. A message may only claim what its check
/// actually measured (L11), and a liveness signal that proves only its own
/// emitter is alive actively reassures (L106).
///
/// The run reports its steps now, so the three states are told apart from the
/// run's own report rather than from a timer: it started, it is still alive
/// because it said something recently, and it has gone quiet.
enum OCRProgressText {

    /// What the footer says, and whether it is a warning rather than reassurance.
    struct Footer: Equatable {
        let text: String
        let isStalled: Bool
    }

    /// The phase label. The run's own step when it has reported one, otherwise
    /// the elapsed-derived guess, which is honest as a guess but cannot be
    /// evidence of anything.
    static func phase(step: GenerationStep?, fallback: String) -> String {
        guard let step, !step.display.isEmpty else { return fallback }
        return step.display
    }

    static func footer(status: LongRunStatus, estimate: TimeInterval?,
                       formattedEstimate: String?) -> Footer {
        switch status {
        case .stalled(_, let step):
            // Names the step it went quiet in, because that is the part Dan can
            // act on: "something is stuck" tells him nothing he can use.
            let last = step.map { "Last step: \($0.display)." }
                ?? "It has not reported a step yet."
            return Footer(
                text: "Nothing new from the program read for a while. \(last) "
                    + "It may still finish; cancelling and scanning again is safe.",
                isStalled: true)

        case .failed(let message):
            return Footer(text: message, isStalled: true)

        case .working, .idle, .finished:
            if let estimate, let formattedEstimate {
                _ = estimate
                return Footer(text: "Usually \(formattedEstimate).", isStalled: false)
            }
            return Footer(text: "Usually 1 to 2 minutes.", isStalled: false)
        }
    }
}
