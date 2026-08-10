import SwiftUI

/// The one progress indicator for anything that does not return instantly
/// (#95, #96).
///
/// Every long action in this app used to show a static spinner and a fixed
/// "~3 to 6 min" label, which looks exactly the same whether the work is
/// progressing, hung, or dead. This shows the three apart:
///
/// * it started, and how long ago
/// * it is still alive, by naming the step the run last reported
/// * it has gone quiet for longer than this work ever should, in a state that
///   says so rather than spinning forever
///
/// Reads the step file the Python run writes, so "still alive" is the run's own
/// report rather than the fact that a process handle exists.
struct LongRunIndicator: View {
    /// What this action is, in Dan's language. Shown until the run reports
    /// something more specific.
    let label: String
    /// When this run started. nil renders nothing.
    let startedAt: Date?
    /// Event whose progress file to read, when this action is a Python run.
    /// nil gives elapsed time only, which is still three states better than a
    /// bare spinner.
    var eventID: UUID? = nil
    /// Which of that event's two runs to read. Captions and graphics report to
    /// separate files because they run at the same time (#234).
    var run: Run = .captions

    enum Run {
        case captions, media

        func file(forEventID id: UUID) -> URL {
            switch self {
            case .captions: return AppPaths.progressFile(forEventID: id)
            case .media:    return AppPaths.mediaProgressFile(forEventID: id)
            }
        }
    }
    /// A rough duration, shown as context next to the elapsed time.
    var estimate: String? = nil
    /// Set when the run has already failed; always wins over the rest.
    var failedMessage: String? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let step = eventID.flatMap {
                LongRunState.readStep(at: run.file(forEventID: $0))
            }
            let status = LongRunState.status(
                startedAt: startedAt, step: step, now: context.date,
                failedMessage: failedMessage)

            switch status {
            case .idle, .finished:
                EmptyView()

            case .working(let seconds, let step):
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small).tint(Color.roseGold)
                    Text(step?.display ?? label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.warmDark)
                    Text(elapsedText(seconds))
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                    if let estimate {
                        Text(estimate)
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                }

            case .stalled(let seconds, let step):
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Still running after \(elapsedText(seconds)), with nothing new for a while")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.roseDeep)
                        // Which step it went quiet in is the actionable part.
                        // "Something is stuck" tells him nothing he can use.
                        Text(step.map { "Last step: \($0.display)" }
                             ?? "It has not reported a step yet.")
                            .font(.light(11))
                            .foregroundStyle(Color.warmMid)
                    }
                }

            case .failed(let message):
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseDeep)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseDeep)
                }
            }
        }
    }

    /// Minutes once it is past a minute: "412s" is a number to decode, "6m 52s"
    /// is a length of time.
    private func elapsedText(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
