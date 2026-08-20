import SwiftUI
import AppKit


// Full-width 9:16 thumbnail for a generated story/collage/before-after graphic.
struct PreviewGraphicThumbnail: View {
    let url: URL
    let onPreview: () -> Void
    var isRegenerating: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var maxHeight: CGFloat? = nil
    @State private var load: ImageLoad = .loading

    private var resolvedMaxHeight: CGFloat {
        maxHeight ?? max(440, (NSScreen.main?.visibleFrame.height ?? 800) * 0.82)
    }

    var body: some View {
        Group {
            load.thumbnail(iconSize: 22, labelSize: 11)
        }
        .aspectRatio(9/16, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: resolvedMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
        )
        // Dim + spinner while regenerating
        .overlay {
            if isRegenerating {
                ZStack {
                    PaintedSurfaces.photoScrim
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(PaintedSurfaces.photoScrimText)
                        Text("Regenerating…")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(PaintedSurfaces.photoScrimText)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 13))
                    .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                    .padding(8)
                    .background(PaintedSurfaces.photoScrim)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the graphic at full size")
            .help("Open the graphic at full size")
            .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            if let onRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(PaintedSurfaces.photoScrimIcon)
                        .padding(8)
                        .background(PaintedSurfaces.photoScrim)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate the graphic")
                .disabled(isRegenerating)
                .help("Regenerate this graphic")
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isRegenerating { onPreview() } }
        .task { load = await ImageLoad.read(url) }
    }
}
struct ReviewThumb: View {
    let url: URL
    let onTap: () -> Void
    @State private var load: ImageLoad = .loading

    var body: some View {
        Group {
            load.thumbnail()
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task { load = await ImageLoad.read(url) }
    }
}
