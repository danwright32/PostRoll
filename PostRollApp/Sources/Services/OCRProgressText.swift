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

    // MARK: - What the two screens call themselves (#622)
    //
    // Both here rather than one word typed into each view, for the reason the
    // phase table moved here in #607: the check has to see the string the app
    // shows. It also makes them a PAIR, which is the whole defect. They are
    // read one after the other and nothing else ever reads either of them, so
    // the contradiction only existed in the reading and each sentence was
    // defensible alone (L118).

    /// The tracked label under the event's name while the program is being
    /// read.
    static let readingHeading = "Reading Program"

    /// The heading on the screen that says the read did not work.
    ///
    /// Was "OCR Failed", which is the name for the step inside the code. The
    /// screen before it says the app is reading a program, so the two together
    /// read as two features, on the one screen that reports a paid read did not
    /// work and offers the way to run it again (#622).
    static let failureHeading = "Couldn't read the program"

    /// The phase label. The run's own step when it has reported one, otherwise
    /// the elapsed-derived guess, which is honest as a guess but cannot be
    /// evidence of anything.
    static func phase(step: GenerationStep?, fallback: String) -> String {
        guard let step, !step.display.isEmpty else { return fallback }
        return step.display
    }

    /// The guess, tied to elapsed seconds, last matching entry winning.
    private static let phases: [(from: Int, label: String)] = [
        (0,  "Converting program pages…"),
        (5,  "Sending to Claude…"),
        (10, "Reading the program…"),
        (18, "Extracting performers…"),
        (25, "Gathering program notes…"),
        (32, "Analyzing context…"),
        (40, "Almost there…"),
    ]

    /// What the screen says before the run has reported a step of its own.
    ///
    /// The thresholds scale to the estimated duration so the labels track how
    /// long reads on this Mac actually take, rather than a shape chosen once.
    ///
    /// Here rather than inside the view (#607) so that the render check drawing
    /// this screen shows the string the app shows. A phase table only the view
    /// could reach would have left that check picking its own words, which is a
    /// picture of a screen the app never draws (L48).
    static func elapsedPhase(elapsedSeconds: Int, estimate: TimeInterval?) -> String {
        let scaled: [(from: Int, label: String)] = {
            guard let estimate else { return phases }
            let base = Double(phases.last?.from ?? 40)
            let scale = estimate / base
            return phases.map { (Int((Double($0.from) * scale).rounded()), $0.label) }
        }()
        return scaled.last { $0.from <= elapsedSeconds }?.label ?? phases[0].label
    }

    /// The elapsed timer under the phase label.
    static func elapsed(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
