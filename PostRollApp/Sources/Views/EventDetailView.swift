import SwiftUI

struct EventDetailView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
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
        // NavigationSplitView keeps this view's slot fixed when the user
        // switches events in the sidebar, so without an explicit identity
        // SwiftUI reuses the same View instance and all @State (including
        // cached preview-PNG paths) leaks from the previous event. Tying
        // identity to event.id forces a clean remount per event.
        .id(event.id)
    }
}
