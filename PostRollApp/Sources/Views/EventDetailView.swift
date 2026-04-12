import SwiftUI

struct EventDetailView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    var body: some View {
        switch event.stage {
        case .created:
            ProgramUploadView(event: event)
        case .programUploaded:
            OCRProgressView(event: event)
        case .ocrDone:
            OCRReviewView(event: event)
        case .photosAssigned:
            PhotoAssignmentView(event: event)
        case .assetsGenerated:
            AssetGenerationView(event: event)
        case .captionsReviewed:
            CaptionReviewView(event: event)
        case .exported:
            ExportView(event: event)
        }
    }
}

// MARK: - Coming soon placeholder

private struct ComingSoonView: View {
    let event: Event

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Text(event.name)
                .font(.signPainter(36))
                .foregroundStyle(Color.warmDark)

            VStack(spacing: 6) {
                StagePill(stage: event.stage)
                Text("This step is coming soon.")
                    .font(.light(13))
                    .foregroundStyle(Color.warmMid)
            }

            RoseGoldDivider()
                .frame(width: 80)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cream)
    }
}
