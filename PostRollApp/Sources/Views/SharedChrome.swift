import SwiftUI

/// Small chrome shared across screens, kept out of any one screen's file so
/// a view that uses them can be rendered without dragging that screen (and
/// its app state) along with it (#393).

// MARK: - Stage Back Button (reused across stages)

struct StageBackButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Color.warmMid)
        }
        .buttonStyle(.plain)
    }
}

struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(configuration.isPressed ? Color.roseDeep : Color.roseGold)
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .focusEffectDisabled()
    }
}
