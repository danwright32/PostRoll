import SwiftUI


/// The Instagram grid cover card: thumbnail, AI rationale (or none once a
/// manual override is in effect), a Regenerate button (reuses
/// PreviewGraphicThumbnail's own, no new UI needed), a manual override
/// escape hatch, and an elapsed-timer progress state. Shared by Friday's
/// dual-slot layout and the generic split layout (Thursday) so the two
/// never diverge.
struct CoverSlotView: View {
    let coverURL: URL
    let rationale: String?
    var isRegenerating: Bool = false
    var regenStartedAt: Date? = nil
    var onPreview: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onChooseOverride: (() -> Void)? = nil
    var maxHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("COVER")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                Spacer()
                if let onChooseOverride {
                    Button(action: onChooseOverride) {
                        Text("Choose a different photo…")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .disabled(isRegenerating)
                }
            }
            .padding(.top, Spacing.md)

            PreviewGraphicThumbnail(
                url: coverURL,
                onPreview: { onPreview?() },
                isRegenerating: isRegenerating,
                onRegenerate: onRegenerate,
                maxHeight: maxHeight
            )
            .padding(.top, Spacing.xs)

            if let rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.light(11))
                    .italic()
                    .foregroundStyle(PaintedSurfaces.secondaryText)
                    .padding(.top, Spacing.xs)
            }

            if regenStartedAt != nil {
                PipelineStatusView(startedAt: regenStartedAt)
                    .padding(.top, Spacing.xs)
            }
        }
    }
}
