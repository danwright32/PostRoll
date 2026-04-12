import SwiftUI

struct OCRProgressView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @State private var errorMessage: String?
    @State private var runID = UUID()

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
    }

    // MARK: - Progress state

    private var progressView: some View {
        VStack(spacing: Spacing.lg) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.roseGold)

            VStack(spacing: 6) {
                Text(event.name)
                    .font(.signPainter(28))
                    .foregroundStyle(Color.warmDark)

                Text("Reading Program")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(Color.roseGold)
            }

            Text("Claude is extracting performers, pieces, and notes.\nThis usually takes 15 to 30 seconds.")
                .font(.light(13))
                .foregroundStyle(Color.warmMid)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
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
                self.errorMessage = nil
                self.runID = UUID()
            }
            .buttonStyle(BrandButtonStyle())
        }
    }

    // MARK: - Bridge

    @MainActor
    private func runOCR() async {
        do {
            let result = try await PythonBridge.shared.runOCR(imagePaths: event.programImagePaths)
            var updated = event
            updated.ocrResult = result
            updated.stage = .ocrDone
            appState.updateEvent(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
