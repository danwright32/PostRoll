import SwiftUI
import AppKit

/// Drawn over a photo in the Thursday strip that is marked to be left out, until
/// "Apply changes" renders the strip without it.
///
/// Does not take taps: the cell beneath still receives them, so tapping a
/// marked photo in removal mode unmarks it.
struct LeftOutMark: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        PaintedSurfaces.photoScrim
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                    Text("Left out")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(PaintedSurfaces.photoScrimText)
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Left out of the reel")
    }
}

/// The photographs the rendered strip does not show, under the strip, each one
/// a control that puts it back.
///
/// A photo restored since the last render stays in the row, marked as coming
/// back, until "Apply changes" draws it into the strip again: dropping it from
/// the row at once would leave it shown nowhere, which reads as lost.
struct LeftOutRow: View {
    let items: [ReelRemoval.LeftOut]
    let isRegenerating: Bool
    let onToggle: (URL) -> Void
    let onRestoreAll: () -> Void

    @Environment(\.inkSurface) private var inkSurface
    private var ink: SurfaceInk { PaintedSurfaces.ink(on: inkSurface) }

    private var leftOutCount: Int { items.filter { !$0.returning }.count }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Spacing.sm) {
                    Text("Left out (\(leftOutCount))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.strong)
                    Spacer()
                    if leftOutCount > 0 {
                        Button("Restore all", action: onRestoreAll)
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(ink.accentText)
                            .disabled(isRegenerating)
                    }
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 6) {
                        ForEach(items, id: \.url) { item in
                            LeftOutThumb(item: item, onTap: { onToggle(item.url) })
                                .disabled(isRegenerating)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct LeftOutThumb: View {
    let item: ReelRemoval.LeftOut
    let onTap: () -> Void

    @State private var image: NSImage?

    private let side: CGFloat = 52

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    PaintedSurfaces.photoPlaceholder
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .overlay {
                if item.returning {
                    PaintedSurfaces.photoScrim
                        .overlay {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(PaintedSurfaces.photoScrimText)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.returning
                            ? "\(item.url.lastPathComponent), back in the reel on the next render"
                            : "\(item.url.lastPathComponent), left out of the reel")
        .accessibilityHint(item.returning ? "Leaves it out again" : "Puts it back in the reel")
        .help(item.returning ? "Back in the reel on the next render. Click to leave it out again."
                             : "Put back in the reel")
        .task(id: item.url) {
            image = await ImageLoad.read(item.url, fitting: side * 2).image
        }
    }
}
