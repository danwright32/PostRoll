import SwiftUI

/// The warning that the PostRoll being run is older than the code, and the
/// button that fixes it (#686).
///
/// Centred over the window rather than tucked into a corner: it is the one
/// thing that explains "the fix you asked for is not in this app", and a quiet
/// line somewhere is exactly what gets missed while the wrong build is used all
/// day.
///
/// Shown once per launch, only when the app is definitely behind. Not knowing
/// goes to the log: a popup that cannot say anything actionable is one that
/// gets dismissed on reflex, and the real warning goes with it.
///
/// It used to print the command and offer to copy it, which left the last step
/// to Dan in a terminal he does not live in. Everything needed to run it was
/// already here: which checkout, and which of the two remedies. The command is
/// still spelled out, but now only where it is the useful answer, which is when
/// the update has failed and doing it by hand is the way round it.
struct BuildBehindSheet: View {
    /// The whole verdict, rather than its four fields taken apart and put back
    /// together to start an update. What decides the sentence, the command and
    /// what the button runs is one value, and splitting it here would give the
    /// sheet a way to describe one verdict while updating another.
    let behind: BuildBehind

    private var builtAt: Date { behind.builtAt }
    private var latestCommit: Date { behind.latestCommit }
    /// What actually fixes it, which decides both the sentence and what the
    /// button runs: rebuilding a checkout that is itself behind changes nothing.
    private var remedy: BuildFreshness.Remedy { behind.remedy }
    private var repo: URL { behind.repo }

    @Environment(AppState.self) private var appState
    /// What is running, across every owner rather than the three this sheet
    /// used to name (#862).
    @Environment(\.workInFlight) private var workInFlight
    @Environment(\.dismiss) private var dismiss

    private var command: String {
        BuildFreshness.command(for: remedy, repo: repo)
    }

    private var isUpdating: Bool { appState.updateStartedAt != nil }

    /// Why pressing Update now would do harm, or nil when it is safe.
    ///
    /// Asked of the three managers that own background work, because installing
    /// quits the app and anything mid flight loses whatever it has not written
    /// back yet.
    private var busyReason: String? {
        AppUpdate.busyReason(workInFlight: workInFlight)
    }

    var body: some View {
        ZStack {
            PaintedSurfaces.page.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(PaintedSurfaces.iconAccent)
                        Text("PostRoll is out of date")
                            .font(.signPainter(28))
                            .foregroundStyle(PaintedSurfaces.bodyText)
                    }
                    RoseGoldDivider()
                }

                Text(BuildFreshness.message(builtAt: builtAt,
                                            latestCommit: latestCommit,
                                            remedy: remedy))
                    .font(.system(size: 13))
                    .foregroundStyle(PaintedSurfaces.bodyText)
                    .fixedSize(horizontal: false, vertical: true)

                if isUpdating {
                    updating
                } else if let failure = appState.updateFailure {
                    failed(failure)
                } else if let refusal = appState.updateRefusal {
                    refused(refusal)
                }

                Spacer(minLength: 0)

                buttons
            }
            .padding(Spacing.xl)
        }
        .frame(width: 520)
        // A height rather than a fixed one: the failure state carries what the
        // build actually said, and a notice that gets clipped is one that was
        // never shipped (L76, L79).
        .frame(minHeight: 380)
        // The update quits and reopens the app. Letting the sheet be waved away
        // mid update would have PostRoll vanish under Dan with nothing on
        // screen having said it was going to.
        .interactiveDismissDisabled(isUpdating)
        // Polled rather than watched: the updater is a separate process writing
        // a file, and it may well outlive this window. Keyed on the start, so
        // the loop ends with the run and a retry starts a new one.
        .task(id: appState.updateStartedAt) {
            while appState.updateStartedAt != nil {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                appState.checkUpdateOutcome()
            }
        }
    }

    // MARK: - While it runs

    private var updating: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // The one progress indicator this app has, reading the step file the
            // updater writes in the same shape a generation writes its own. It
            // shows working, still alive, and gone quiet apart, which a spinner
            // over a five minute build cannot.
            LongRunIndicator(label: "Updating PostRoll",
                             startedAt: appState.updateStartedAt,
                             stepFile: appState.updateProgressFile,
                             estimate: "usually 3 to 6 min")

            Text("The tests run first, so this takes a few minutes. PostRoll "
                 + "will close and reopen itself once the new version is "
                 + "installed.")
                .font(.system(size: 12))
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - When it did not work

    private func failed(_ outcome: AppUpdate.Outcome) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(AppUpdate.failureMessage(outcome), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PaintedSurfaces.pageAccentText)
                .fixedSize(horizontal: false, vertical: true)

            if !outcome.message.isEmpty {
                ScrollView {
                    Text(outcome.message)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(PaintedSurfaces.bodyText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 110)
                .background(boxBackground)
            }

            // The command earns its place HERE, and only here: when the button
            // could not do it, doing it by hand is the way round, and the
            // terminal will say more than these last lines can.
            Text("To do it by hand:")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
            commandBox

            Text("The whole log is at \(appState.updateLogDisplayPath)")
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
        }
    }

    private func refused(_ reason: String) -> some View {
        Label(reason, systemImage: "hourglass")
            .font(.system(size: 12))
            .foregroundStyle(PaintedSurfaces.pageAccentText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Pieces

    /// The command on its own line, in the shape it is typed, so it can be read
    /// straight off the screen as well as copied.
    private var commandBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(PaintedSurfaces.bodyText)
                .frame(maxWidth: .infinity, alignment: .leading)
            ClipboardCopyButton(text: command, what: "update command", size: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(boxBackground)
    }

    private var boxBackground: some View {
        RoundedRectangle(cornerRadius: Radius.sm)
            .fill(PaintedSurfaces.deepPage)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 12) {
            if !isUpdating {
                Button(appState.updateFailure == nil ? "Update now" : "Try again") {
                    appState.startUpdate(for: behind, busyReason: busyReason)
                }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
            }

            Spacer()

            // Not offered while an update is running: the sheet is the only
            // thing saying the app is about to close itself.
            if !isUpdating {
                Button("Carry on for now") {
                    // Acknowledged, so the reason is not reported again at the
                    // next launch. Dismissing without having failed leaves
                    // nothing to acknowledge.
                    appState.dismissUpdateFailure()
                    appState.dismissUpdateRefusal()
                    dismiss()
                }
                .buttonStyle(.link)
            }
        }
    }
}
