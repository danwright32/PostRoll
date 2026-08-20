import SwiftUI
import AppKit


struct InlineReelPhotoAssignment: View {
    var rawPhoto: URL?
    var editedPhoto: URL?
    var bwPhoto: URL? = nil
    var isRegenerating: Bool = false
    var onPickRaw: () -> Void
    var onPickEdited: () -> Void
    var onPickBW: () -> Void
    var onClearBW: () -> Void
    var onGenerate: () -> Void

    private var hasAll: Bool { rawPhoto != nil && editedPhoto != nil }

    var body: some View {
        VStack(spacing: Spacing.md) {
            Text("REEL")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(PaintedSurfaces.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Assign the RAW and Edited photos to generate a speed-edit reel.")
                .font(.light(12))
                .foregroundStyle(PaintedSurfaces.secondaryText)

            HStack(alignment: .top, spacing: Spacing.md) {
                photoSlot(label: "RAW (unedited)", url: rawPhoto, action: onPickRaw)
                photoSlot(label: "Edited", url: editedPhoto, action: onPickEdited)
                VStack(spacing: Spacing.xs) {
                    photoSlot(label: "B&W (optional)", url: bwPhoto, action: onPickBW)
                    if bwPhoto != nil {
                        Button("Remove") { onClearBW() }
                            .buttonStyle(.plain)
                            .font(.system(size: 9))
                            .foregroundStyle(PaintedSurfaces.pageAccentText)
                    }
                }
            }

            if bwPhoto != nil {
                Text("3-photo post: reel reveals color over B&W, Friday shows all three.")
                    .font(.light(10))
                    .foregroundStyle(PaintedSurfaces.pageAccentText)
                    .multilineTextAlignment(.center)
            }

            if hasAll {
                if isRegenerating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PaintedSurfaces.iconAccent)
                } else {
                    Button("Generate Reel") { onGenerate() }
                        .buttonStyle(BrandButtonStyle())
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }

    @ViewBuilder
    private func photoSlot(label: String, url: URL?, action: @escaping () -> Void) -> some View {
        VStack(spacing: Spacing.xs) {
            Button { action() } label: {
                if let url, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                } else {
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(PaintedSurfaces.addTreatmentFill)
                        .frame(width: 120, height: 80)
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                                Text("Choose")
                                    .font(.system(size: 10))
                                    .foregroundStyle(PaintedSurfaces.secondaryText)
                            }
                        }
                }
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PaintedSurfaces.secondaryText)
        }
    }
}
