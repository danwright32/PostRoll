import SwiftUI

struct OCRProgressView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @State private var errorMessage: String?
    @State private var runID = UUID()
    @State private var elapsed: Int = 0
    @State private var phaseOverride: String? = nil

    // Phases are tied to elapsed seconds — last matching entry wins
    private static let phases: [(from: Int, label: String)] = [
        (0,  "Converting program pages…"),
        (5,  "Sending to Claude…"),
        (10, "Reading the program…"),
        (18, "Extracting performers…"),
        (25, "Gathering program notes…"),
        (32, "Analyzing context…"),
        (40, "Almost there…"),
    ]

    // Scale phase thresholds to the estimated OCR duration so labels track reality.
    private var scaledPhases: [(from: Int, label: String)] {
        guard let est = TimingStore.shared.ocrEstimate else { return Self.phases }
        let base = Double(Self.phases.last?.from ?? 40)
        let scale = est / base
        return Self.phases.map { (Int((Double($0.from) * scale).rounded()), $0.label) }
    }

    private var currentPhase: String {
        phaseOverride ?? (scaledPhases.last { $0.from <= elapsed }?.label ?? Self.phases[0].label)
    }

    private var elapsedText: String {
        String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private var footerText: String {
        if let est = TimingStore.shared.ocrEstimate {
            let overrun = Double(elapsed) > est * 1.4
            return overrun
                ? "Taking longer than usual. Still working."
                : "Usually \(TimingStore.formatEstimate(est))."
        }
        return elapsed >= 45
            ? "Taking a little longer than usual. Still working."
            : "Usually 1 to 2 minutes."
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
        .background(Color.cream)
        .task(id: runID) { await runOCR() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard errorMessage == nil else { return }
            elapsed += 1
        }
    }

    // MARK: - Progress state

    private var progressView: some View {
        VStack(spacing: Spacing.lg) {
            // Event identity
            VStack(spacing: 6) {
                Text(event.name)
                    .font(.signPainter(28))
                    .foregroundStyle(Color.warmDark)

                Text("Reading Program")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(Color.roseGold)
            }

            // Shimmer line — the alive signal, replaces the system spinner
            OCRShimmerLine()
                .frame(width: 260, height: 1.5)
                .padding(.vertical, 4)

            // Phase label — crossfades between stages
            Text(currentPhase)
                .font(.light(13))
                .foregroundStyle(Color.warmMid)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: currentPhase)

            // Elapsed timer — hard proof it hasn't stalled
            Text(elapsedText)
                .font(.system(size: 22, weight: .light, design: .monospaced))
                .foregroundStyle(Color.roseGold.opacity(0.6))
                .monospacedDigit()

            // Footer — softens after 45s
            Text(footerText)
                .font(.light(11))
                .foregroundStyle(Color.warmFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: footerText)

            Button("Cancel") { cancelOCR() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.warmMid)
                .padding(.top, Spacing.sm)
        }
    }

    // MARK: - Error state

    private func errorView(_ message: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(Color.roseGold)

            VStack(spacing: 6) {
                Text("OCR Failed")
                    .font(.signPainter(28))
                    .foregroundStyle(Color.warmDark)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmMid)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Button("Try Again") {
                errorMessage = nil
                elapsed = 0
                runID = UUID()
            }
            .buttonStyle(BrandButtonStyle())
        }
    }

    // MARK: - Bridge

    @MainActor
    private func runOCR() async {
        elapsed = 0

        // Defensive guard: if program images are missing (e.g. cleaned up by
        // a stale background sweep, or a Back-from-review path that lost them),
        // route the user back to the upload screen instead of running the
        // Python script with no --image args.
        let livePaths = (appState.events.first(where: { $0.id == event.id }) ?? event)
            .programImagePaths
        if livePaths.isEmpty {
            var ev = appState.events.first(where: { $0.id == event.id }) ?? event
            ev.stage = .created
            appState.updateEvent(ev)
            return
        }

        do {
            var result = try await PythonBridge.shared.runOCR(imagePaths: livePaths)

            // DCINY events: the website lists conductors + group names (preferred over
            // the program, which lists every individual choir/orchestra member).
            let url = event.eventURL
            if !url.isEmpty, url.lowercased().contains("dciny.org") {
                phaseOverride = "Fetching performers from website…"
                if let webPerformers = try? await PythonBridge.shared.fetchWebPerformers(eventURL: url),
                   !webPerformers.isEmpty {
                    result.performers = webPerformers
                }
            }

            TimingStore.shared.recordOCR(seconds: Double(elapsed))

            // Second pass: ask Claude to flag suspicious items in the OCR output.
            // The user resolves these on the OCR review screen before continuing.
            // If flagging fails (rate limit, payload size, etc.), don't block —
            // the user can still review the OCR data manually. Capture the
            // reason so OCRReviewView can surface it as a banner.
            phaseOverride = "Checking for issues…"
            var flags: [OCRFlag] = []
            var flagError: String? = nil
            do {
                flags = try await PythonBridge.shared.runFlagIssues(
                    ocr: result,
                    imagePaths: livePaths
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                flagError = error.localizedDescription
            }

            // Program images stay on disk through the review step — flag review
            // could conceivably need them later. They're cleaned up when the
            // user confirms OCR review, in OCRReviewView.confirmAndAdvance().
            // Base the write-back on the live event: OCR takes minutes and a
            // snapshot would revert edits (e.g. a rename) made during the run.
            var updated = appState.events.first(where: { $0.id == event.id }) ?? event
            updated.ocrResult = result
            updated.pendingFlags = flags
            updated.pendingFlagsError = flagError
            updated.stage = .ocrDone
            appState.updateEvent(updated)
            NotificationService.shared.notifyOCRComplete(eventName: event.name)
        } catch is CancellationError {
            // User cancelled — navigation already handled by cancelOCR()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancelOCR() {
        // Read live from appState — `let event` at view init can go stale.
        // Reverting to .created tears down this view, which cancels .task and
        // sends SIGTERM to the Python OCR process (see PythonBridge.runProcess).
        // programImagePaths are preserved so the user can retry from the upload screen.
        var ev = appState.events.first(where: { $0.id == event.id }) ?? event
        ev.stage = .created
        appState.updateEvent(ev)
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
                    .fill(Color.roseGold.opacity(0.15))

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
