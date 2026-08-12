import SwiftUI

/// The four screens the generation stage can show, each taking plain values and
/// closures rather than reaching for AppState and GenerationManager (#396).
///
/// Same shape as `HaltedWeekBody` and `ExportDoneSummary` before them, and for
/// the same reason: while these lived inside `AssetGenerationView` as private
/// computed properties, looking at any of them meant standing up the whole app
/// and reaching the state for real. Getting a week to fail on Thursday, or to
/// come back from a cap, is not something a check can do, so the copy on these
/// screens had never been read rendered.
///
/// Nothing here decides anything. The behaviour, the live reads and the writes
/// all stay in the screen; these only draw what they are handed.

// MARK: - Configure

/// What the generation screen shows before a run starts.
struct GenerationConfigureBody: View {
    let daysCount: Int
    /// Every photo the run will use, days and blog together, which is also what
    /// decides whether it can start at all.
    let totalPhotos: Int
    let hasBlog: Bool
    var onGenerate: () -> Void = {}

    /// One predicate for the button's enabled state and the sentence explaining
    /// it, so a disabled button can never sit there with nothing said (L109).
    var canGenerate: Bool { totalPhotos > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GenerationSummaryRow(daysCount: daysCount,
                                 totalPhotos: totalPhotos,
                                 hasBlog: hasBlog)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.lg)

            VStack(alignment: .trailing, spacing: Spacing.sm) {
                if !canGenerate {
                    Text("Add photos to at least one day to generate.")
                        .font(.light(11))
                        .foregroundStyle(Color.warmMid)
                }
                HStack {
                    Spacer()
                    Button("Generate All", action: onGenerate)
                        .buttonStyle(BrandButtonStyle())
                        .disabled(!canGenerate)
                }
            }
            .padding(Spacing.xl)
        }
    }
}

// MARK: - Running

/// What the generation screen shows while a run is in flight.
struct GenerationRunningBody: View {
    let eventName: String
    /// Full run or partial retry, from `GenerationRunPlan.subtitle`.
    let subtitle: String
    let phases: [GenerationRunPlan.Phase]
    let activePhaseIndex: Int
    let elapsedFormatted: String
    let estimatedTotalFormatted: String
    /// The staggered reveal. Defaults to shown, because every row in this column
    /// is opacity gated on it and a render taken before the animation ran would
    /// measure a blank page while looking correct.
    var revealed: Bool = true
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Text(eventName)
                .font(.signPainter(28))
                .foregroundStyle(Color.warmDark)

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.warmMid)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                    PhaseRow(name: phase.name, state: state(at: i))
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 6)
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.82)
                                .delay(Double(i) * 0.07),
                            value: revealed
                        )
                }
            }
            .animation(.easeOut(duration: 0.3), value: activePhaseIndex)
            .padding(.vertical, Spacing.sm)

            HStack(spacing: Spacing.xs) {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                Text(elapsedFormatted)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Text("/ \(estimatedTotalFormatted)")
                    .font(.light(12))
            }
            .foregroundStyle(Color.warmMid)

            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.warmMid.opacity(0.7))
                .padding(.top, Spacing.sm)
        }
    }

    private func state(at index: Int) -> PhaseState {
        index < activePhaseIndex  ? .completed :
        index == activePhaseIndex ? .active    : .pending
    }
}

// MARK: - Error

/// What the generation screen shows when a run failed outright.
///
/// A week stopped by a usage cap is a different screen (`HaltedWeekBody`): an
/// error state and a partial success are not the same thing (#257).
struct GenerationErrorBody: View {
    let message: String
    /// Whether there is a previous week to fall back on. Decides whether the way
    /// out that keeps existing work is offered at all.
    let hasPreviousResults: Bool
    var onUsePrevious: () -> Void = {}
    var onFixInputs: () -> Void = {}
    var onTryAgain: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            BrandBanner(icon: "exclamationmark.triangle", message: message, style: .error)
                .padding(.horizontal, Spacing.xl)

            HStack(spacing: Spacing.md) {
                Spacer()
                if hasPreviousResults {
                    Button("Use previous results", action: onUsePrevious)
                        .buttonStyle(BrandOutlineButtonStyle())
                }
                Button("Fix inputs", action: onFixInputs)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.roseGold)
                Button("Try Again", action: onTryAgain)
                    .buttonStyle(BrandButtonStyle())
            }
            .padding(Spacing.xl)
        }
    }
}

// MARK: - Done

/// One failed day, as the done screen shows it.
struct GenerationFailureCard: Identifiable, Equatable {
    /// The day (or `blog`, or the graphics key) this failure belongs to.
    let id: String
    let label: String
    /// Produced by `GenerationFailureText.humanize`, never written here.
    let message: String
    /// Whether Dan can resolve it by changing inputs, which decides whether the
    /// route back to the photo screen is offered.
    let fixable: Bool
}

/// One day Dan can re-run on its own.
///
/// Carries the key as well as the label, because the label is what he reads and
/// the key is what the run needs. Passing only the label and lowercasing it back
/// works right up to the first key that is not a day name.
struct GenerationRegenerableDay: Identifiable, Equatable {
    let id: String
    let label: String
}

/// What the generation screen shows once a run has finished, clean or not.
struct GenerationDoneBody: View {
    let eventName: String
    /// From `RunOutcomeNotice.headline`, so the words and the mark below cannot
    /// disagree about whether the week finished.
    let headline: String
    /// A run that reached the end of the week with nothing failed. Anything less
    /// gets the hollow mark, including a week the watchdog cut off (#262).
    let isUnqualifiedSuccess: Bool
    /// The verbatim text of a failure the cap detector did not recognise, which
    /// before #262 only ever appeared on stderr.
    var unfamiliarNote: String? = nil
    var failures: [GenerationFailureCard] = []
    /// Days Dan can re-run one at a time.
    var regenerableDays: [GenerationRegenerableDay] = []
    /// The program PDF control's label, which says which state the bake is in.
    /// nil hides it, because this event has no program.
    var programPDFLabel: String? = nil
    var programPDFDisabled: Bool = false
    /// A bake that failed. Before #80 a `try?` dropped this and the program just
    /// stopped existing with nothing said.
    var programBakeError: String? = nil
    var hasBlog: Bool = false
    /// The reveal animation. Defaults to shown for the same reason as the running
    /// screen: everything below the name is gated on it.
    var revealed: Bool = true

    var onContinue: () -> Void = {}
    var onFixInputs: () -> Void = {}
    var onRetryFailures: () -> Void = {}
    var onRegenerateDay: (String) -> Void = { _ in }
    var onDownloadProgramPDF: () -> Void = {}
    var onRetryProgramBake: () -> Void = {}
    var onRegenerateBlog: () -> Void = {}
    var onRegenerateAll: () -> Void = {}

    /// The set named on the retry button, built from the cards on screen so the
    /// two can never name different days (L16).
    var failedDaysSummary: String {
        GenerationFailureText.summarySentence(failures.map(\.label))
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Text(eventName)
                .font(.signPainter(28))
                .foregroundStyle(Color.warmDark)

            Image(systemName: isUnqualifiedSuccess ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(Color.roseGold.opacity(0.7))
                .scaleEffect(revealed ? 1 : 0.1)
                .opacity(revealed ? 1 : 0)

            Text(headline)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.warmDark)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 8)

            if let unfamiliarNote {
                Text(unfamiliarNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warmDark.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(Spacing.sm)
                    .background(Color.roseGold.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    .opacity(revealed ? 1 : 0)
            }

            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(failures) { info in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(info.label.uppercased())
                                .font(.system(size: 9, weight: .medium))
                                .tracking(1.1)
                                .foregroundStyle(Color.roseDeep)
                            Text(info.message)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.warmDark)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                        .background(Color.roseDeep.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                    }
                }
                .frame(maxWidth: 460)
                .opacity(revealed ? 1 : 0)
            }

            RoseGoldDivider()
                .frame(width: revealed ? 80 : 0)

            actions
                .opacity(revealed ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    /// Its own property rather than inline: the whole screen in one expression
    /// sits past what the view builder will type check.
    private var actions: some View {
        VStack(spacing: Spacing.sm) {
            Button("Continue to Review", action: onContinue)
                .buttonStyle(BrandButtonStyle())

            if !failures.isEmpty {
                if failures.contains(where: \.fixable) {
                    Button("Fix inputs", action: onFixInputs)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.roseGold)
                }
                Button("Retry \(failedDaysSummary)", action: onRetryFailures)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
            }

            if !regenerableDays.isEmpty {
                Menu {
                    ForEach(regenerableDays) { day in
                        Button(day.label) { onRegenerateDay(day.id) }
                    }
                } label: {
                    Label("Regenerate one day…", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.roseGold)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if let programPDFLabel {
                Button(programPDFLabel, action: onDownloadProgramPDF)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
                    .disabled(programPDFDisabled)
            }

            if let programBakeError {
                // The reason is closed through Sentence rather than followed by a
                // full stop of our own: an OS error already ends in one, and
                // rendering this screen for the first time is what showed the
                // double stop it produced (#396).
                BrandBanner(
                    icon: "exclamationmark.triangle",
                    message: "The searchable program PDF couldn't be built: "
                           + Sentence.closed(programBakeError)
                           + " The page scans have been kept.",
                    style: .error,
                    actions: [BrandBannerAction(label: "Try again", action: onRetryProgramBake)]
                )
            }

            if hasBlog {
                // The accent, like every other paid shortcut in this stack (#398).
                Button("Regenerate blog post", action: onRegenerateBlog)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.roseGold)
            }

            Button("Regenerate all", action: onRegenerateAll)
                .buttonStyle(BrandOutlineButtonStyle())
        }
    }
}

// MARK: - Generation summary row

private struct GenerationSummaryRow: View {
    let daysCount: Int
    let totalPhotos: Int
    let hasBlog: Bool

    var body: some View {
        HStack(spacing: Spacing.xl) {
            SummaryStat(value: "\(daysCount)", label: "DAYS")
            SummaryStat(value: "\(totalPhotos)", label: "PHOTOS")
            if hasBlog {
                SummaryStat(value: "1", label: "BLOG POST")
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.creamDeep)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.creamEdge, lineWidth: 1)
        )
    }
}

private struct SummaryStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.signPainter(26))
                .foregroundStyle(Color.roseGold)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.warmMid)
        }
    }
}

// MARK: - Phase row

private enum PhaseState: Equatable {
    case pending, active, completed
}

private struct PhaseRow: View {
    let name: String
    let state: PhaseState

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.roseGold.opacity(0.5))
                case .active:
                    Image(systemName: "circle.fill")
                        .foregroundStyle(Color.roseGold)
                        .symbolEffect(.pulse)
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(Color.creamEdge)
                }
            }
            .font(.system(size: 12))
            .frame(width: 16, alignment: .center)

            Text(name)
                .font(.system(size: 13, weight: state == .active ? .medium : .regular))
                .foregroundStyle(
                    state == .pending  ? Color.warmMid.opacity(0.5) :
                    state == .active   ? Color.warmDark             : Color.warmMid
                )
        }
        .animation(.easeOut(duration: 0.25), value: state)
    }
}
