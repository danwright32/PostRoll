import SwiftUI
import AppKit

struct LabeledReviewThumb: View {
    let url: URL
    let label: String
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ReviewThumb(url: url, onTap: onTap)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(PaintedSurfaces.secondaryText)
        }
    }
}
struct ReviewMediaFileRow: View {
    let url: URL
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(PaintedSurfaces.iconAccent)
            Text(label)
                .font(.light(11))
                .foregroundStyle(PaintedSurfaces.secondaryText)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(PaintedSurfaces.pageAccentText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(PaintedSurfaces.deepPage)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .strokeBorder(PaintedSurfaces.edgeRule, lineWidth: 0.5)
                )
        )
    }
}
