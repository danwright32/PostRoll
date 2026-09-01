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
    /// A step file named outright, for work that belongs to no event.
    ///
    /// Updating the app is the one such thing (#686): there is one PostRoll, so
    /// its progress has nowhere to be keyed. Given its own file rather than a
    /// second indicator grown beside this one, because the three states this
    /// draws are exactly the three that update needs.
    var stepFile: URL? = nil
    /// Which of that event's two runs to read. Captions and graphics report to
    /// separate files because they run at the same time (#234).
    var run: Run = .captions

    /// CaseIterable so the tests can hold this to the set of progress files
    /// `AppPaths` can write: a run whose file nothing here reads shows as a
    /// bare spinner however much it writes (#1128, L46).
    enum Run: CaseIterable {
        case captions, media, ocr, blog, blogPhotos, blogRetry

        func file(forEventID id: UUID) -> URL {
            switch self {
            case .captions:   return AppPaths.progressFile(forEventID: id)
            case .media:      return AppPaths.mediaProgressFile(forEventID: id)
            case .ocr:        return AppPaths.ocrProgressFile(forEventID: id)
            case .blog:       return AppPaths.blogProgressFile(forEventID: id)
            case .blogPhotos: return AppPaths.blogPhotoSwapProgressFile(forEventID: id)
            case .blogRetry:  return AppPaths.blogRepairRetryProgressFile(forEventID: id)
            }
        }
    }
    /// A rough duration, shown as context next to the elapsed time.
    var estimate: String? = nil
    /// Set when the run has already failed; always wins over the rest.
    var failedMessage: String? = nil
    /// How long this particular work may go quiet before it is shown as
    /// stalled. The default is sized to a Claude call, which is the slowest
    /// thing this app waits on; local work (a CSV parse, a Vision OCR pass)
    /// takes a fraction of that, and holding it to the same threshold would
    /// mean a hung one still looked healthy ten minutes in (#460).
    var silenceThreshold: TimeInterval = LongRunState.defaultSilenceThreshold

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // A named file wins over the event's own, because a caller passing
            // one has said where to look and falling back would read somebody
            // else's run.
            let file = stepFile ?? eventID.map { run.file(forEventID: $0) }
            let step = file.flatMap { LongRunState.readStep(at: $0) }
            let status = LongRunState.status(
                startedAt: startedAt, step: step, now: context.date,
                failedMessage: failedMessage,
                silenceThreshold: silenceThreshold)

            switch status {
            case .idle, .finished:
                EmptyView()

            case .working(let seconds, let step):
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small).tint(PaintedSurfaces.iconAccent)
                    Text(step?.display ?? label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PaintedSurfaces.bodyText)
                    Text(elapsedText(seconds))
                        .font(.light(11))
                        .foregroundStyle(PaintedSurfaces.secondaryText)
                    if let estimate {
                        Text(estimate)
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                    }
                }

            case .stalled(let seconds, let step):
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Still running after \(elapsedText(seconds)), with nothing new for a while")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                        // Which step it went quiet in is the actionable part.
                        // "Something is stuck" tells him nothing he can use.
                        Text(step.map { "Last step: \($0.display)" }
                             ?? "It has not reported a step yet.")
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.secondaryText)
                    }
                }

            case .failed(let message):
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
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
