import SwiftUI

struct OCRProgressView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(OCRManager.self) private var ocrManager

    /// Derived from the app-scoped run so OCR survives the view being torn down
    /// when the user switches events (the detail pane is `.id(event.id)`-tagged).
    private var run: OCRManager.Run? { ocrManager.run(for: event.id) }
    private var errorMessage: String? {
        if case .failed(let msg) = run?.status { return msg }
        return nil
    }
    private var elapsed: Int { run?.elapsedSeconds ?? 0 }
    private var phaseOverride: String? { run?.phaseOverride }

    /// The guess shown until the run reports a step of its own. The table and
    /// the scaling live in `OCRProgressText` (#607).
    private var currentPhase: String {
        phaseOverride ?? OCRProgressText.elapsedPhase(elapsedSeconds: elapsed,
                                                      estimate: TimingStore.shared.ocrEstimate)
    }

    /// When this run started, for measuring silence against.
    private var startedAt: Date? {
        run == nil ? nil : Date().addingTimeInterval(-Double(elapsed))
    }

    /// What the run itself last reported, read fresh (#467).
    private func liveStatus(now: Date) -> LongRunStatus {
        LongRunState.status(
            startedAt: startedAt,
            step: LongRunState.readStep(at: AppPaths.ocrProgressFile(forEventID: event.id)),
            now: now,
            failedMessage: nil,
            // OCR is Claude calls of up to 600s each, so it is held to the
            // threshold sized for that rather than the local-work one.
            silenceThreshold: LongRunState.defaultSilenceThreshold)
    }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            if let errorMessage {
                errorView(errorMessage)
            } else {
                progressView
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaintedSurfaces.page)
        // start() is synchronous and idempotent: it kicks off the app-scoped run
        // (a no-op if one is already in flight) so remounting on an event switch
        // resumes showing the same run instead of launching a duplicate.
        .onAppear { ocrManager.start(eventID: event.id, appState: appState) }
    }

    // MARK: - Progress state

    private var progressView: some View {
        OCRProgressBody(
            eventName: event.name,
            // Phase, timer and footer all come from what the run last
            // reported, re-read every second (#467). The elapsed timer alone
            // proves only that this app is running, so on its own it is a
            // liveness signal for the wrong process (L106).
            live: { now in
                let step = LongRunState.readStep(
                    at: AppPaths.ocrProgressFile(forEventID: event.id))
                return OCRProgressBody.Live(
                    phase: OCRProgressText.phase(step: step, fallback: currentPhase),
                    elapsedText: OCRProgressText.elapsed(seconds: elapsed),
                    footer: OCRProgressText.footer(
                        status: liveStatus(now: now),
                        estimate: TimingStore.shared.ocrEstimate,
                        formattedEstimate: TimingStore.shared.ocrEstimate
                            .map(TimingStore.formatEstimate)))
            },
            onCancel: cancelOCR)
    }

    // MARK: - Error state

    private func errorView(_ message: String) -> some View {
        OCRFailureBody(
            message: message,
            onRetry: {
                ocrManager.clearOutcome(eventID: event.id)
                ocrManager.start(eventID: event.id, appState: appState)
            },
            onGoBack: cancelOCR)
    }

    // MARK: - Cancel

    private func cancelOCR() {
        // Cancel the app-scoped run (SIGTERMs Python via task cancellation in
        // PythonBridge.runProcess), then navigate back. Read live from
        // appState — `let event` at view init can go stale. programImagePaths
        // are preserved so the user can retry from the upload screen.
        ocrManager.cancel(eventID: event.id)
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.stage = .created
        appState.updateEvent(ev)
    }
}

// MARK: - The reading screen

/// The screen shown while a program is being read, with nothing behind it
/// (#607).
///
/// Split out of `OCRProgressView` so it can be drawn in a test. The view above
/// reads the run from the environment and starts one in `onAppear`, so
/// rendering it would launch a paid Claude read; this half is handed what it
/// shows and does nothing (L2). Nothing had ever confirmed the words on this
/// screen reach it, which is the one Dan sits in front of for minutes at a
/// time.
struct OCRProgressBody: View {

    /// What the run last reported. Read on every tick rather than passed once,
    /// because the timer and the footer are the two things that must not go
    /// stale.
    struct Live: Equatable {
        let phase: String
        let elapsedText: String
        let footer: OCRProgressText.Footer
    }

    let eventName: String
    let live: (Date) -> Live
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Event identity
            VStack(spacing: 6) {
                Text(eventName)
                    .font(.signPainter(28))
                    .foregroundStyle(Color.warmDark)

                Text("Reading Program")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
            }

            // Shimmer line: the alive signal, replacing the system spinner
            OCRShimmerLine()
                .frame(width: 260, height: 1.5)
                .padding(.vertical, 4)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = live(context.date)

                VStack(spacing: Spacing.lg) {
                    Text(now.phase)
                        .font(.light(13))
                        .foregroundStyle(Color.warmMid)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.5), value: now.phase)

                    // Elapsed timer, which says how long rather than whether
                    // anything is happening.
                    Text(now.elapsedText)
                        .font(.system(size: 22, weight: .light, design: .monospaced))
                        .foregroundStyle(PaintedSurfaces.pageAccentText)
                        .monospacedDigit()

                    if now.footer.isStalled {
                        Label(now.footer.text, systemImage: "exclamationmark.triangle")
                            .font(.light(11))
                            .foregroundStyle(Color.roseDeep)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    } else {
                        Text(now.footer.text)
                            .font(.light(11))
                            .foregroundStyle(PaintedSurfaces.tertiaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.6), value: now.footer.text)
                    }
                }
            }

            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.warmMid)
                .padding(.top, Spacing.sm)
        }
    }
}

// MARK: - The screen a read fails on

/// The screen shown when a program could not be read, with nothing behind it
/// (#613).
///
/// The sibling of `OCRProgressBody`, split out for the same reason and drawn by
/// nothing until now: the heading, the reason the read failed, Try Again and Go
/// Back had never been rendered or measured. It matters slightly more than an
/// ordinary notice because it is the only screen that says a paid read did not
/// work, and the only place the way to run it again is offered.
///
/// Handed its message rather than reading the run from the environment, so
/// rendering it cannot start a paid Claude read (L2).
struct OCRFailureBody: View {
    let message: String
    let onRetry: () -> Void
    let onGoBack: () -> Void

    /// One thing this screen offers, nameable so the render check can measure
    /// what that thing alone puts on the page.
    ///
    /// A whole-screen ink measurement cannot do it here: the 44pt symbol and
    /// the filled Try Again button are marks on the page whatever the type
    /// does, and a filled button measured 0.2475 of a surface almost all of it
    /// its own background (#559, L141). So each part is compared against the
    /// same screen with that part gone, which isolates what it is worth.
    ///
    /// Try Again is the whole control rather than its label, because a button
    /// style owns its own title: what that part proves is that the way to run
    /// the read again is on the screen. Its label being readable ON the fill is
    /// the primary button pair in `PaintedSurfaces`, which is measured next
    /// door.
    enum Part: String, CaseIterable {
        case heading
        case reason
        case tryAgain
        case goBack
    }

    #if POSTROLL_TESTS
    /// Behind the test-only flag so the shipping app cannot reach it.
    var hidden: Set<Part> = []
    private func opacity(_ part: Part) -> Double { hidden.contains(part) ? 0 : 1 }
    #else
    private func opacity(_ part: Part) -> Double { 1 }
    #endif

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(PaintedSurfaces.iconAccent)

            VStack(spacing: 6) {
                Text("OCR Failed")
                    .font(.signPainter(28))
                    .foregroundStyle(Color.warmDark)
                    .opacity(opacity(.heading))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmMid)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .opacity(opacity(.reason))
            }

            Button("Try Again") { onRetry() }
                .buttonStyle(BrandButtonStyle())
                .opacity(opacity(.tryAgain))

            Button("Go Back") { onGoBack() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.warmMid)
                .opacity(opacity(.goBack))
        }
    }
}

// MARK: - Shimmer Line

/// A thin horizontal track with a rose-gold highlight that travels
/// continuously left → right, proving the process is alive.
private struct OCRShimmerLine: View {
    @State private var offset: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Dim track
                Capsule()
                    .fill(PaintedSurfaces.shimmerTrack)

                // Travelling highlight
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: Color.roseGold, location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: offset * geo.size.width)
            }
        }
        .onAppear {
            offset = -0.35
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                offset = 1.0
            }
        }
    }
}
