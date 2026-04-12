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
